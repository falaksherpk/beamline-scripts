#!/usr/bin/env bash
# HDB++ archiving (handbook Part 3, Ch30), seen from tango-db: hdbpp.target and both
# server units active and enabled; the EventSubscriber and ConfigurationManager ON and
# exported from tango-db; the EventSubscriber archiving the expected number of attributes,
# all of them OK, its saved AttributeList equal to its running one; every archived
# attribute stored at least once in the EventSubscriber's last statistics window (60 s;
# with the 10 s archive_period heartbeat a live attribute stores about 6), and no store
# failed. From here (beamlinehost, on the lab network): each server's fixed CORBA and
# heartbeat port accepts, the nat0 side stays closed. The ZeroMQ event ports are not
# probed (opened only once a client subscribes). Read-only: nothing is written, no
# command is sent to a device, no SQL is run.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"

# Overridable only to test the check against a wrong target (checks.d/README.md).
HOST=${CHECK_HDBPP_HOST:-tango-db.beamline}
# The host the servers export from, as the Tango database records it (gethostname()).
SERVER_HOST=${CHECK_HDBPP_SERVER_HOST:-$HOST}
EXPECT_ATTRS=${CHECK_HDBPP_EXPECT_ATTRS:-17}
REACH_PORTS=${CHECK_HDBPP_REACH_PORTS:-28373 28374 28473 28474}
# What beamline-ansible's tango_db role configures (Ch30: tango_db_hdbpp_servers,
# tango_db_hdbpp_archive, the ufw blocks); keep the two in step.
TANGO_HOST_VAL=${CHECK_HDBPP_TANGO_HOST:-tango-db.beamline:10000}
ES_DEV=archiving/hdbpp/eventsubscriber01
CM_DEV=archiving/hdbpp/confmanager01
UNITS="es cm"
NAT_IFACE=nat0
PROBE_TIMEOUT=3

# Runs on tango-db as FLEET_SSH_USER; nothing needs root. The values above go first,
# quoted by printf %q; the whole program travels base64-encoded, so its quoting does
# not depend on two shells.
remote=$( {
  printf 'units=%q tango_host=%q expect_host=%q es_dev=%q cm_dev=%q expect=%q nat=%q\n' \
    "$UNITS" "$TANGO_HOST_VAL" "$SERVER_HOST" "$ES_DEV" "$CM_DEV" "$EXPECT_ATTRS" "$NAT_IFACE"
  cat << 'SH'
say() { printf '%s|%s\n' "$1" "$2"; }
one() { tr '\n' ' ' <<< "$1" | tr -s ' ' | sed 's/ $//' | cut -c1-200; }

# 1. The target and both units.
read -ra unit_list <<< "$units"
for u in hdbpp.target "${unit_list[@]/#/hdbpp-}"; do
  a=$(systemctl is-active "$u" 2>&1)
  e=$(systemctl is-enabled "$u" 2>&1)
  if [[ $a == active && $e == enabled ]]; then say OK "$u: active, enabled"
  else say FAIL "$u: $(one "$a"), $(one "$e") (want active, enabled)"; fi
done

# 2. Both devices ON, exported from this host; 3. the EventSubscriber's view.
TANGO_HOST=$tango_host timeout 30 python3 -c '
import sys
try:
    import tango
except ImportError as e:
    print("CANNOT|hdbpp: no PyTango here: %s" % e)
    sys.exit(0)
es_name, cm_name, expect_host, expect = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    db = tango.Database()
except tango.DevFailed as e:
    print("FAIL|database: %s does not answer: %s" % (sys.argv[5], e.args[0].reason))
    sys.exit(0)
# A device that answers is checked further even when not ON: the EventSubscriber goes to
# ALARM when an attribute fails, and the details below then name that attribute.
up = {}
for name in (es_name, cm_name):
    try:
        # DbGetDeviceInfo, not get_device_info(): the latter has no host in PyTango 9.5.
        flags, info = db.command_inout("DbGetDeviceInfo", name)
        exported, host = flags[0] == 1, info[4]
        d = tango.DeviceProxy(name)
        d.set_timeout_millis(3000)
        state = d.state()
    except tango.DevFailed as e:
        print("FAIL|%s: %s" % (name, e.args[0].reason))
        continue
    served = "exported" if exported else "not exported"
    if state == tango.DevState.ON and exported and host == expect_host:
        print("OK|%s: ON, %s from %s" % (name, served, host))
    else:
        print("FAIL|%s: %s, %s from %s (want ON, exported from %s)" % (name, state, served, host, expect_host))
    up[name] = d
es = up.get(es_name)
if es is None:
    print("CANNOT|archiving: not checked, %s does not answer" % es_name)
    sys.exit(0)
try:
    running = [a.lower() for a in (es.read_attribute("AttributeList").value or [])]
    ok, nok, pending = (es.read_attribute(a).value for a in
                        ("AttributeOkNumber", "AttributeNokNumber", "AttributePendingNumber"))
    nok_list = list(es.read_attribute("AttributeNokList").value or [])
    saved = db.get_device_property(es_name, ["AttributeList"])["AttributeList"]
    saved = [s.split(";")[0].lower() for s in saved]
    freq = es.read_attribute("AttributeRecordFreqList")
    fail_total = es.read_attribute("AttributeFailureFreq").value
    stats_age = es.read_attribute("StatisticsResetTime").value
except tango.DevFailed as e:
    print("CANNOT|archiving: %s attributes unreadable: %s" % (es_name, e.args[0].reason))
    sys.exit(0)
def short(n):
    """domain/family/member/attribute, without tango://host:port/."""
    return n.split("/", 3)[-1]


if len(running) == expect and ok == expect and nok == 0 and pending == 0:
    print("OK|archiving: %d of %d attributes OK (Nok 0, Pending 0)" % (ok, expect))
else:
    print("FAIL|archiving: %d archived, %d OK, Nok %d %s, Pending %d (want %d, all OK)"
          % (len(running), ok, nok, [short(n) for n in nok_list][:5], pending, expect))
if sorted(saved) == sorted(running):
    print("OK|archiving: saved AttributeList equals the running one (%d)" % len(saved))
else:
    lost = sorted(set(running) - set(saved))
    extra = sorted(set(saved) - set(running))
    print("FAIL|archiving: saved and running AttributeList differ: running only %s, saved only %s"
          % ([short(n) for n in lost][:5], [short(n) for n in extra][:5]))
# The statistics cover the last complete 60 s window: during the first one after a start
# (or a ResetStatistics) the list reads all zeros and the failure count None.
values = list(freq.value) if freq.value is not None else []
if stats_age is None or stats_age < 60 or fail_total is None or len(values) != len(running):
    print("CANNOT|archiving: no complete 60 s statistics window yet (statistics %s s old), freshness not checked"
          % ("unknown" if stats_age is None else int(stats_age)))
else:
    stale = [short(n) for n, f in zip(running, values, strict=True) if f < 1]
    if stale:
        print("FAIL|archiving: %d attribute(s) stored nothing in the last 60 s: %s" % (len(stale), stale[:5]))
    else:
        print("OK|archiving: every attribute stored in the last 60 s (%d to %d records each)"
              % (min(values), max(values)) if values else "OK|archiving: no attributes to check")
    if fail_total == 0:
        print("OK|archiving: no failed event or store in the last 60 s")
    else:
        print("FAIL|archiving: %d failed event(s) or store(s) in the last 60 s (want 0)" % fail_total)
' "$es_dev" "$cm_dev" "$expect_host" "$expect" "$tango_host" || say CANNOT "hdbpp: python3 exit $?"

# The nat0 address, for the exposure probe run from beamlinehost.
n=$(ip -4 -o addr show dev "$nat" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
say NAT "$n"
say END "reached"
SH
} | base64 -w0 )

rc=0
out=$(fleet_ssh "$HOST" "echo $remote | base64 -d | bash" 2>&1) || rc=$?
nat_ip=""
if (( rc == 255 )); then
  fleet_check_cannot "ssh to $HOST failed: ${out:0:300}"
else
  n=0 end=0
  while IFS='|' read -r kind msg; do
    case $kind in
      OK) fleet_check_ok "$msg"; n=$(( n + 1 )) ;;
      FAIL) fleet_check_fail "$msg"; n=$(( n + 1 )) ;;
      CANNOT) fleet_check_cannot "$msg"; n=$(( n + 1 )) ;;
      NAT) nat_ip=$msg ;;
      END) end=1 ;;
    esac
  done <<< "$out"
  if (( rc != 0 || end == 0 )); then
    fleet_check_cannot "checks on $HOST did not reach their end (exit $rc, $n verdict(s)); last output: $(tail -n 2 <<< "$out" | tr '\n' ' ')"
  fi
fi

# probe HOST PORT -> 0 accepted, 1 refused, 124 no answer (dropped), other: error.
probe() {
  local prc=0
  timeout "$PROBE_TIMEOUT" bash -c "exec 3<>/dev/tcp/$1/$2" 2> /dev/null || prc=$?
  return "$prc"
}

# 4. Reach, from beamlinehost (on the lab network, which ufw allows): each fixed port
#    must accept. Refused means nothing listens; no answer means the firewall drops it.
if ! getent hosts "$HOST" > /dev/null; then
  fleet_check_cannot "reach: $HOST does not resolve here, ports not probed"
else
  for p in $REACH_PORTS; do
    prc=0; probe "$HOST" "$p" || prc=$?
    case $prc in
      0)   fleet_check_ok "reach: $HOST:$p accepts connections from the lab network" ;;
      1)   fleet_check_fail "reach: $HOST:$p refused: no server listens (want accepted)" ;;
      124) fleet_check_fail "reach: $HOST:$p does not answer: dropped (want accepted)" ;;
      *)   fleet_check_cannot "reach: $HOST:$p probe exit $prc" ;;
    esac
  done
fi

# 5. The servers bind the lab address only, and ufw allows the lab network only: the
#    first CORBA port on the nat0 address must be dropped.
first_port=${REACH_PORTS%% *}
if [[ -z $nat_ip ]]; then
  fleet_check_cannot "exposure: no $NAT_IFACE address read from $HOST, nat0 side not probed"
else
  prc=0; probe "$nat_ip" "$first_port" || prc=$?
  case $prc in
    124) fleet_check_ok "exposure: $HOST:$first_port via $NAT_IFACE ($nat_ip) does not answer (dropped)" ;;
    0)   fleet_check_fail "exposure: $HOST:$first_port via $NAT_IFACE ($nat_ip) accepts connections (want dropped)" ;;
    1)   fleet_check_fail "exposure: $HOST:$first_port via $NAT_IFACE ($nat_ip) refused: the firewall let it through (want dropped)" ;;
    *)   fleet_check_cannot "exposure: $HOST:$first_port via $NAT_IFACE probe exit $prc" ;;
  esac
fi

fleet_check_exit
