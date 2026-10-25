#!/usr/bin/env bash
# Sardana (handbook Part 3, Ch31), seen from tango-ds: the Pool and MacroServer units
# active and enabled; pool/linac/1, macroserver/linac/1 and door/linac/1 exported from
# tango-ds, the Pool and MacroServer ON, the Door ON or RUNNING (a scan may be running);
# the lab's elements on the Pool, each ON or MOVING; the MacroServer knowing every
# element the Pool has (a MacroServer that doesn't yet answers "does not exist in any
# Pool", Ch31); ActiveMntGrp set to the lab's measurement group. From here (beamlinehost,
# on the lab network): each server's fixed CORBA and heartbeat port accepts, the nat0
# side stays closed. The ZeroMQ event ports are not probed (opened only once a client
# subscribes). Read-only: nothing is written, no command is sent to a device, no macro
# is run.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"

# Overridable only to test the check against a wrong target (checks.d/README.md).
HOST=${CHECK_SARDANA_HOST:-tango-ds.beamline}
# The host the servers export from, as the Tango database records it (gethostname()).
SERVER_HOST=${CHECK_SARDANA_SERVER_HOST:-$HOST}
ELEMENTS=${CHECK_SARDANA_ELEMENTS:-magnet_mot fc_ctr fc_mg}
MNTGRP=${CHECK_SARDANA_MNTGRP:-fc_mg}
REACH_PORTS=${CHECK_SARDANA_REACH_PORTS:-28366 28367 28466 28467}
# What beamline-ansible's tango_ds role configures (Ch31: tango_ds_sardana_servers,
# tango_ds_sardana_elements, the ufw blocks); keep the two in step.
TANGO_HOST_VAL=tango-db.beamline:10000
POOL_DEV=pool/linac/1
MS_DEV=macroserver/linac/1
DOOR_DEV=door/linac/1
UNITS="pool macroserver"
NAT_IFACE=nat0
PROBE_TIMEOUT=3

# Runs on tango-ds as FLEET_SSH_USER; nothing needs root. The values above go first,
# quoted by printf %q; the whole program travels base64-encoded, so its quoting does
# not depend on two shells.
remote=$( {
  printf 'units=%q tango_host=%q expect_host=%q pool=%q ms=%q door=%q elements=%q mntgrp=%q nat=%q\n' \
    "$UNITS" "$TANGO_HOST_VAL" "$SERVER_HOST" "$POOL_DEV" "$MS_DEV" "$DOOR_DEV" "$ELEMENTS" "$MNTGRP" "$NAT_IFACE"
  cat << 'SH'
say() { printf '%s|%s\n' "$1" "$2"; }
one() { tr '\n' ' ' <<< "$1" | tr -s ' ' | sed 's/ $//' | cut -c1-200; }

# 1. Both units.
read -ra unit_list <<< "$units"
for u in "${unit_list[@]/#/tango-}"; do
  a=$(systemctl is-active "$u" 2>&1)
  e=$(systemctl is-enabled "$u" 2>&1)
  if [[ $a == active && $e == enabled ]]; then say OK "$u: active, enabled"
  else say FAIL "$u: $(one "$a"), $(one "$e") (want active, enabled)"; fi
done

# 2. The three devices exported from this host and in a good state; 3. the Pool's
#    elements; 4. what the MacroServer knows; 5. its ActiveMntGrp.
TANGO_HOST=$tango_host timeout 30 python3 -c '
import json
import pickle
import sys

try:
    import tango
except ImportError as e:
    print(f"CANNOT|sardana: no PyTango here: {e}")
    sys.exit(0)
pool_name, ms_name, door_name, expect_host, tango_host = sys.argv[1:6]
want, mntgrp = sys.argv[6].split(), sys.argv[7]
try:
    db = tango.Database()
except tango.DevFailed as e:
    print(f"FAIL|database: {tango_host} does not answer: {e.args[0].reason}")
    sys.exit(0)
# The states each server may be in: the Door is RUNNING while a macro (a scan) runs.
good = {
    pool_name: (tango.DevState.ON,),
    ms_name: (tango.DevState.ON,),
    door_name: (tango.DevState.ON, tango.DevState.RUNNING),
}
up = {}
for name, states in good.items():
    try:
        # DbGetDeviceInfo, as in 85-hdbpp.sh: its host field does not depend on the
        # PyTango version.
        flags, info = db.command_inout("DbGetDeviceInfo", name)
        exported, host = flags[0] == 1, info[4]
        d = tango.DeviceProxy(name)
        d.set_timeout_millis(3000)
        state = d.state()
    except tango.DevFailed as e:
        print(f"FAIL|{name}: {e.args[0].reason}")
        continue
    served = "exported" if exported else "not exported"
    if state in states and exported and host == expect_host:
        print(f"OK|{name}: {state}, {served} from {host}")
    else:
        want_states = " or ".join(str(s) for s in states)
        print(
            f"FAIL|{name}: {state}, {served} from {host}"
            f" (want {want_states}, exported from {expect_host})"
        )
    up[name] = d

pool, ms = up.get(pool_name), up.get(ms_name)
have = {}
if pool is None:
    print(f"CANNOT|elements: not checked, {pool_name} does not answer")
else:
    try:
        for attr in ("MotorList", "ExpChannelList", "MeasurementGroupList"):
            for s in pool.read_attribute(attr).value or []:
                item = json.loads(s)
                have[item["name"]] = item["full_name"]
    except (tango.DevFailed, ValueError, KeyError) as e:
        print(f"CANNOT|elements: {pool_name} lists unreadable: {e}")
        pool = None
if pool is not None:
    for name in want:
        if name not in have:
            print(f"FAIL|element {name}: not on {pool_name} (want it created, Ch31)")
            continue
        try:
            element = tango.DeviceProxy(have[name])
            element.set_timeout_millis(3000)
            state = element.state()
        except tango.DevFailed as e:
            print(f"FAIL|element {name}: {e.args[0].reason}")
            continue
        # MOVING: the motor or the measurement group is in a scan.
        if state in (tango.DevState.ON, tango.DevState.MOVING):
            print(f"OK|element {name}: {state} on {pool_name}")
        else:
            print(f"FAIL|element {name}: {state} (want ON or MOVING)")

if ms is None:
    print(f"CANNOT|macroserver: not checked, {ms_name} does not answer")
    sys.exit(0)
try:
    fmt, data = ms.read_attribute("Elements").value
    known = {e["name"] for e in json.loads(data).get("new", [])}
    # Our own MacroServer pickles its Environment (the format Sardana clients read).
    efmt, edata = ms.read_attribute("Environment").value
    env = pickle.loads(edata).get("new", {}) if efmt == "pickle" else None
except (tango.DevFailed, ValueError, KeyError, TypeError, pickle.UnpicklingError) as e:
    print(f"CANNOT|macroserver: {ms_name} attributes unreadable: {e}")
    sys.exit(0)
if fmt != "utf8_json":
    print(f"CANNOT|macroserver: Elements format {fmt}, want utf8_json")
else:
    # The ones we expect, plus whatever else the Pool has: the readiness meaning.
    expected = set(want) | set(have)
    missing = sorted(expected - known)
    if missing:
        print(
            f"FAIL|macroserver: does not know {len(missing)} Pool element(s):"
            f" {missing[:5]}"
        )
    else:
        print(f"OK|macroserver: knows all {len(expected)} Pool element(s)")
active = None if env is None else env.get("ActiveMntGrp")
if env is None:
    print(f"CANNOT|macroserver: Environment format {efmt}, want pickle")
elif active == mntgrp:
    print(f"OK|macroserver: ActiveMntGrp is {mntgrp}")
else:
    print(f"FAIL|macroserver: ActiveMntGrp is {active} (want {mntgrp})")
' "$pool" "$ms" "$door" "$expect_host" "$tango_host" "$elements" "$mntgrp" || say CANNOT "sardana: python3 exit $?"

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

# 6. Reach, from beamlinehost (on the lab network, which ufw allows): each fixed port
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

# 7. The servers bind the lab address only, and ufw allows the lab network only: the
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
