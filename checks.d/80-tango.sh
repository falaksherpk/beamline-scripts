#!/usr/bin/env bash
# Tango control system (handbook Part 3, Ch29), seen from tango-ds: tango-lab.target and
# every device-server and simulator unit active and enabled; the Tango database
# answering; each lab device ON, exported and served from tango-ds. From here
# (beamlinehost, on the lab network): each server's fixed CORBA and heartbeat port
# accepts connections, while the simulators' ports and the servers' nat0 side stay
# closed. The ZeroMQ event ports are not probed: a server opens one only once a client
# subscribes. Read-only: nothing is written, no command is sent to a device.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"

# Overridable only to test the check against a wrong target (checks.d/README.md).
HOST=${CHECK_TANGO_HOST:-tango-ds.beamline}
REACH_PORTS=${CHECK_TANGO_REACH_PORTS:-28368 28369 28370 28371 28372 28468 28469 28470 28471 28472}
CLOSED_PORTS=${CHECK_TANGO_CLOSED_PORTS:-9999 5025 1234 5020 5040}
# What beamline-ansible's tango_ds role configures (Ch29: tango_ds_servers,
# tango_ds_simulators, the ufw blocks); keep the two in step.
TANGO_HOST_VAL=tango-db.beamline:10000
DEVICES="linac/magnet/q1 linac/beam/faradaycup1 linac/camera/ceyag1 linac/vacuum/gauge1 linac/safety/interlock1"
UNITS="magnet-socat magnet-psu faradaycup-picoammeter faradaycup-adapter camera-sim vacuum-sim interlock-sim magnet faradaycup camera vacuum interlock"
NAT_IFACE=nat0
PROBE_TIMEOUT=3

# Runs on tango-ds as FLEET_SSH_USER; nothing needs root. The values above go first,
# quoted by printf %q; the whole program travels base64-encoded, so its quoting does
# not depend on two shells.
remote=$( {
  printf 'units=%q devices=%q tango_host=%q expect_host=%q nat=%q\n' "$UNITS" "$DEVICES" "$TANGO_HOST_VAL" "$HOST" "$NAT_IFACE"
  cat << 'SH'
say() { printf '%s|%s\n' "$1" "$2"; }
one() { tr '\n' ' ' <<< "$1" | tr -s ' ' | sed 's/ $//' | cut -c1-200; }

# 1. The target and every unit.
read -ra unit_list <<< "$units"
for u in tango-lab.target "${unit_list[@]/#/tango-}"; do
  a=$(systemctl is-active "$u" 2>&1)
  e=$(systemctl is-enabled "$u" 2>&1)
  if [[ $a == active && $e == enabled ]]; then say OK "$u: active, enabled"
  else say FAIL "$u: $(one "$a"), $(one "$e") (want active, enabled)"; fi
done

# 2. The database answers; 3. every device ON, exported, served from this host.
TANGO_HOST=$tango_host timeout 30 python3 -c '
import sys
try:
    import tango
except ImportError as e:
    print("CANNOT|devices: no PyTango here: %s" % e)
    sys.exit(0)
devices, expect_host = sys.argv[1].split(), sys.argv[2]
try:
    db = tango.Database()
    first = db.get_info().splitlines()[0]
except tango.DevFailed as e:
    print("FAIL|database: %s does not answer: %s" % (sys.argv[3], e.args[0].reason))
    for name in devices:
        print("CANNOT|%s: not checked, no database" % name)
    sys.exit(0)
print("OK|database: %s answers (%s)" % (sys.argv[3], first.strip()))
for name in devices:
    try:
        info = db.get_device_info(name)
        d = tango.DeviceProxy(name)
        d.set_timeout_millis(3000)
        state, status = d.state(), d.status().replace("\n", " ")[:80]
    except tango.DevFailed as e:
        print("FAIL|%s: %s" % (name, e.args[0].reason))
        continue
    served = "exported" if info.exported else "not exported"
    if state == tango.DevState.ON and info.exported and info.host == expect_host:
        print("OK|%s: ON, %s from %s" % (name, served, info.host))
    else:
        print("FAIL|%s: %s (%s), %s from %s (want ON, exported from %s)"
              % (name, state, status, served, info.host, expect_host))
' "$devices" "$expect_host" "$tango_host" || say CANNOT "devices: python3 exit $?"

# The nat0 address, for the exposure probes run from beamlinehost.
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
  # 5. Exposure: the simulators listen on 127.0.0.1 only, and ufw opens nothing else;
  #    their ports on the lab address must be dropped, not refused or answered.
  for p in $CLOSED_PORTS; do
    prc=0; probe "$HOST" "$p" || prc=$?
    case $prc in
      124) fleet_check_ok "exposure: $HOST:$p (simulator) does not answer from here (dropped)" ;;
      0)   fleet_check_fail "exposure: $HOST:$p (simulator) accepts connections from here (want dropped)" ;;
      1)   fleet_check_fail "exposure: $HOST:$p (simulator) refused: the firewall let it through (want dropped)" ;;
      *)   fleet_check_cannot "exposure: $HOST:$p probe exit $prc" ;;
    esac
  done
fi

# 6. The servers bind the lab address only, and ufw allows the lab network only: the
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
