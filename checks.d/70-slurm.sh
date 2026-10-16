#!/usr/bin/env bash
# SLURM cluster (handbook Ch18), seen from its controller hpc-ctl: munge, MariaDB,
# slurmdbd and slurmctld running and enabled; the controller answering; exactly the
# configured compute nodes, each in a usable state and with its configured GRES
# (Ch20); the accounting chain
# slurmctld -> slurmdbd -> MariaDB answering. From here: the Slurm ports are not
# reachable from beamlinehost (only the HPC nodes may connect, Ch18 ufw rules).
# Read-only: no job is submitted (a job would write accounting records).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"

# Overridable only to test the check against a wrong target (checks.d/README.md).
HOST=${CHECK_SLURM_HOST:-hpc-ctl.beamline}
EXPOSURE=${CHECK_SLURM_EXPOSURE:-hpc-ctl.beamline:6817 hpc-ctl.beamline:6819 hpc-c1.beamline:6818 hpc-gpu.beamline:6818}
# What beamline-ansible's slurm role configures (Ch18); keep the two in step.
CLUSTER=beamline
NODES="hpc-c1 hpc-gpu"
# Each node's GRES as slurmctld knows it (scontrol --json "gres", without the "(S:...)"
# affinity AutoDetect adds); empty = none. Keep in step with slurm_gpu_nodes (Ch20).
GRES="hpc-c1= hpc-gpu=gpu:gtx_750_ti:1"
UNITS="munge mariadb slurmdbd slurmctld"
# Node state flags (scontrol --json) that mean "usable"; anything else is a failure.
GOOD_FLAGS="IDLE MIXED ALLOCATED COMPLETING"
PROBE_TIMEOUT=3

# Runs on the controller as FLEET_SSH_USER; nothing needs root. The values above go
# first, quoted by printf %q; the whole program travels base64-encoded, so its
# quoting does not depend on two shells.
remote=$( {
  printf 'cluster=%q nodes=%q units=%q good=%q gres=%q\n' "$CLUSTER" "$NODES" "$UNITS" "$GOOD_FLAGS" "$GRES"
  cat << 'SH'
say() { printf '%s|%s\n' "$1" "$2"; }
one() { tr '\n' ' ' <<< "$1" | tr -s ' ' | sed 's/ $//' | cut -c1-200; }

# 1. The daemons on the controller.
for u in $units; do
  a=$(systemctl is-active "$u" 2>&1)
  e=$(systemctl is-enabled "$u" 2>&1)
  if [[ $a == active && $e == enabled ]]; then say OK "$u: active, enabled"
  else say FAIL "$u: $(one "$a"), $(one "$e") (want active, enabled)"; fi
done

# 2. The controller answers.
p=$(scontrol ping < /dev/null 2>&1)
prc=$?
if [[ $prc == 0 && $p == *"(primary) at "*" is UP"* ]]; then say OK "controller: $(one "$p")"
else say FAIL "controller: scontrol ping exit $prc: $(one "$p")"; fi

# 3. Exactly the configured nodes, each usable and with its configured GRES (parsed
#    from JSON, not table text).
j=$(scontrol show nodes --json < /dev/null 2>&1)
jrc=$?
if (( jrc != 0 )); then
  say CANNOT "nodes: scontrol show nodes --json exit $jrc: $(one "${j:0:200}")"
else
  python3 -c '
import json, re, sys
want, good = sys.argv[1].split(), set(sys.argv[2].split())
want_gres = dict(t.split("=", 1) for t in sys.argv[3].split())
allowed = "/".join(sorted(good))
try:
    d = json.loads(sys.stdin.read())
except ValueError as e:
    print("CANNOT|nodes: scontrol --json output is not JSON: %s" % e)
    sys.exit(0)
if d.get("errors"):
    print("CANNOT|nodes: scontrol reported errors: %s" % str(d["errors"])[:160])
    sys.exit(0)
nodes = {n.get("name"): n for n in d.get("nodes", [])}
if sorted(nodes) == sorted(want):
    print("OK|nodes: exactly the configured %d: %s" % (len(want), " ".join(want)))
else:
    print("FAIL|nodes: slurmctld knows %s (want %s)" % (sorted(nodes), sorted(want)))
for name in want:
    if name not in nodes:
        continue
    flags = nodes[name].get("state") or []
    reason = nodes[name].get("reason") or ""
    shown = "+".join(flags) or "no state"
    if flags and set(flags) <= good:
        print("OK|node %s: %s" % (name, shown))
    else:
        print("FAIL|node %s: %s, reason \"%s\" (want only %s)" % (name, shown, reason, allowed))
    have = re.sub(r"\([^)]*\)", "", nodes[name].get("gres") or "")
    need = want_gres.get(name, "")
    if have == need:
        print("OK|gres %s: %s" % (name, have or "none"))
    else:
        print("FAIL|gres %s: %s (want %s)" % (name, have or "none", need or "none"))
' "$nodes" "$good" "$gres" <<< "$j" || say CANNOT "nodes: python3 could not evaluate the node list (exit $?)"
fi

# 4. Accounting: slurmctld -> slurmdbd -> MariaDB, by asking slurmdbd for the cluster.
c=$(sacctmgr --noheader --parsable2 show cluster format=cluster < /dev/null 2>&1)
crc=$?
if [[ $crc == 0 ]] && grep -qx "$cluster" <<< "$c"; then
  say OK "accounting: slurmdbd answers, cluster $cluster registered"
else
  say FAIL "accounting: sacctmgr exit $crc, clusters '$(one "$c")' (want $cluster)"
fi
say END "reached"
SH
} | base64 -w0 )

rc=0
out=$(fleet_ssh "$HOST" "echo $remote | base64 -d | bash" 2>&1) || rc=$?
if (( rc == 255 )); then
  fleet_check_cannot "ssh to $HOST failed: ${out:0:300}"
else
  n=0 end=0
  while IFS='|' read -r kind msg; do
    case $kind in
      OK) fleet_check_ok "$msg"; n=$(( n + 1 )) ;;
      FAIL) fleet_check_fail "$msg"; n=$(( n + 1 )) ;;
      CANNOT) fleet_check_cannot "$msg"; n=$(( n + 1 )) ;;
      END) end=1 ;;
    esac
  done <<< "$out"
  if (( rc != 0 || end == 0 )); then
    fleet_check_cannot "checks on $HOST did not reach their end (exit $rc, $n verdict(s)); last output: $(tail -n 2 <<< "$out" | tr '\n' ' ')"
  fi
fi

# 5. Exposure, from beamlinehost: each Slurm port must be dropped (timeout), not
#    refused or answered -- a refusal means the packet got through the firewall.
for target in $EXPOSURE; do
  h=${target%:*} p=${target##*:}
  if ! getent hosts "$h" > /dev/null; then
    fleet_check_cannot "exposure: $h does not resolve here, $h:$p not probed"
    continue
  fi
  prc=0
  timeout "$PROBE_TIMEOUT" bash -c "exec 3<>/dev/tcp/$h/$p" 2> /dev/null || prc=$?
  case $prc in
    124) fleet_check_ok "exposure: $h:$p does not answer from here (dropped)" ;;
    0)   fleet_check_fail "exposure: $h:$p accepts connections from here (want dropped)" ;;
    1)   fleet_check_fail "exposure: $h:$p refused from here: the firewall let it through (want dropped)" ;;
    *)   fleet_check_cannot "exposure: $h:$p probe exit $prc" ;;
  esac
done

fleet_check_exit
