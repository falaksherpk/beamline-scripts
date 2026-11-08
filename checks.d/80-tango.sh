#!/usr/bin/env bash
# Tango control system (handbook Part 3, Ch29; Part 4, Ch35-36), seen from tango-ds:
# tango-lab.target, every device-server and simulator instance of the package's template
# units and the exporter's instance active, enabled and loaded from the package, with the
# environment files they name present; the Tango database answering, through the
# package's runtime; each lab device ON, exported and served from tango-ds. From here
# (beamlinehost, on the lab network): each server's fixed CORBA and heartbeat port
# accepts connections, while the simulators' ports, the exporter's port (obs only) and
# the servers' nat0 side stay closed. The ZeroMQ event ports are not probed: a server opens one only once a client
# subscribes. Read-only: nothing is written, no command is sent to a device.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"

# Overridable only to test the check against a wrong target (checks.d/README.md).
HOST=${CHECK_TANGO_HOST:-tango-ds.beamline}
REACH_PORTS=${CHECK_TANGO_REACH_PORTS:-28368 28369 28370 28371 28372 28468 28469 28470 28471 28472}
CLOSED_PORTS=${CHECK_TANGO_CLOSED_PORTS:-9999 5025 1234 5020 5040}
# The exporter (Part 4 Ch36) answers obs only: from here its port must be dropped.
EXPORTER_PORT=${CHECK_TANGO_EXPORTER_PORT:-9580}
# What beamline-ansible's tango_ds role configures (Ch29: the ufw blocks; Ch35:
# tango_ds_servers and tango_ds_simulators, one instance each; Ch36: the exporter, outside
# the target); keep the two in step.
TANGO_HOST_VAL=tango-db.beamline:10000
DEVICES="linac/magnet/q1 linac/beam/faradaycup1 linac/camera/ceyag1 linac/vacuum/gauge1 linac/safety/interlock1"
UNITS="tango-sim-magnet-link@q1 tango-sim-magnet-psu@q1 tango-sim-picoammeter@faradaycup1 tango-sim-prologix@faradaycup1 tango-sim-camera@ceyag1 tango-sim-vacuum@gauge1 tango-sim-plc@interlock1 tango-magnet@q1 tango-faradaycup@faradaycup1 tango-camera@ceyag1 tango-vacuum@gauge1 tango-interlock@interlock1 tango-exporter@linac"
# The package's runtime: PyTango is not in the system Python since Ch35.
TANGO_PYTHON=/opt/beamline-tango/bin/python3
NAT_IFACE=nat0
PROBE_TIMEOUT=3

# Runs on tango-ds as FLEET_SSH_USER; nothing needs root. The values above go first,
# quoted by printf %q; the whole program travels base64-encoded, so its quoting does
# not depend on two shells.
remote=$( {
  printf 'units=%q devices=%q tango_host=%q expect_host=%q nat=%q python=%q\n' "$UNITS" "$DEVICES" "$TANGO_HOST_VAL" "$HOST" "$NAT_IFACE" "$TANGO_PYTHON"
  cat << 'SH'
say() { printf '%s|%s\n' "$1" "$2"; }
one() { tr '\n' ' ' <<< "$1" | tr -s ' ' | sed 's/ $//' | cut -c1-200; }

# 1. The target and every instance.
# Each active, enabled and loaded from the package (a copy in /etc/systemd/system would
# override it), and every environment file its unit names present: systemd-analyze verify
# doesn't notice a missing one (Ch33), and the instance would fail only at its next start.
read -ra unit_list <<< "$units"
envs=0 missing=()
for u in tango-lab.target "${unit_list[@]}"; do
  a=$(systemctl is-active "$u" 2>&1)
  e=$(systemctl is-enabled "$u" 2>&1)
  p=$(systemctl show -p FragmentPath --value "$u" 2>&1)
  if [[ $a == active && $e == enabled && $p == /usr/lib/systemd/system/* ]]; then say OK "$u: active, enabled, from the package"
  else say FAIL "$u: $(one "$a"), $(one "$e"), unit file $(one "${p:-none}") (want active, enabled, from /usr/lib/systemd/system)"; fi
  while read -r f _; do
    [[ $f == /* ]] || continue
    envs=$(( envs + 1 ))
    [[ -r $f ]] || missing+=("$u: $f")
  done < <(systemctl show -p EnvironmentFiles --value "$u" 2>/dev/null)
done
if (( ${#missing[@]} )); then say FAIL "site data: ${#missing[@]} of $envs environment file(s) missing: ${missing[*]:0:3}"
elif (( envs == 0 )); then say FAIL "site data: no instance names an environment file (want the package's units)"
else say OK "site data: all $envs environment file(s) the instances name are present"; fi

# 2. The database answers; 3. every device ON, exported, served from this host.
TANGO_HOST=$tango_host timeout 30 "$python" -c '
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
' "$devices" "$expect_host" "$tango_host" || say CANNOT "devices: $python exit $?"

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
  # The exporter: ufw admits obs only (its being up is 50-observability's job tango).
  prc=0; probe "$HOST" "$EXPORTER_PORT" || prc=$?
  case $prc in
    124) fleet_check_ok "exposure: $HOST:$EXPORTER_PORT (exporter) does not answer from here (dropped; obs only)" ;;
    0)   fleet_check_fail "exposure: $HOST:$EXPORTER_PORT (exporter) accepts connections from here (want obs only)" ;;
    1)   fleet_check_fail "exposure: $HOST:$EXPORTER_PORT (exporter) refused: the firewall let it through (want dropped)" ;;
    *)   fleet_check_cannot "exposure: $HOST:$EXPORTER_PORT probe exit $prc" ;;
  esac
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
