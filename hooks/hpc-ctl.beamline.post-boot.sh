#!/usr/bin/env bash
# Post-boot hook for hpc-ctl.beamline (handbook Ch18; contract: hooks/README.md).
# Waits, bounded, until slurmctld knows exactly the configured compute nodes and
# each has only usable state flags (the same rule as checks.d/70-slurm.sh).
# It changes nothing: a node that is DOWN or DRAINED for a reason stays so and is
# reported (after a cold boot the nodes come back idle by themselves, Ch18).
# Exit 0 = all nodes usable, 1 = not usable when the wait ran out (states shown),
# 2 = could not check (no answer from ssh or slurmctld until the end).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-up.sh}/fleet-lib.sh"
HOST=${FLEET_HOST:?run from fleet-up.sh}

# What beamline-ansible's slurm role configures (Ch18); keep in step with it and
# with checks.d/70-slurm.sh.
NODES="hpc-c1 hpc-gpu"
GOOD_FLAGS="IDLE MIXED ALLOCATED COMPLETING"
# Below FLEET_HOOK_TIMEOUT, so the hook reports its own outcome before timeout(1) hits.
WAIT=${SLURM_HOOK_WAIT:-45}
INTERVAL=3

errf=$(mktemp) || { echo "SLURM: could not check: mktemp failed"; exit 2; }
trap 'rm -f "$errf"' EXIT

# Prints one line; exit 0 = all usable, 1 = node list seen but not all usable,
# 2 = no usable answer.
evaluate() {
  python3 -c '
import json, sys
want, good = sys.argv[1].split(), set(sys.argv[2].split())
try:
    d = json.loads(sys.stdin.read())
except ValueError as e:
    print("scontrol --json output is not JSON: %s" % e)
    sys.exit(2)
if d.get("errors"):
    print("scontrol reported errors: %s" % str(d["errors"])[:200])
    sys.exit(2)
nodes = {n.get("name"): n for n in d.get("nodes", [])}
parts, bad = [], False
for name in want:
    if name not in nodes:
        parts.append("%s missing" % name)
        bad = True
        continue
    flags = nodes[name].get("state") or []
    reason = nodes[name].get("reason") or ""
    ok = bool(flags) and set(flags) <= good
    bad = bad or not ok
    parts.append("%s %s%s" % (name, "+".join(flags) or "no state", "" if ok or not reason else " (reason \"%s\")" % reason))
extra = sorted(set(nodes) - set(want))
if extra:
    parts.append("unexpected: %s" % " ".join(extra))
    bad = True
print("; ".join(parts))
sys.exit(1 if bad else 0)
' "$NODES" "$GOOD_FLAGS"
}

echo "SLURM: waiting up to ${WAIT}s for nodes ${NODES} to be usable"
start=$SECONDS
while :; do
  rc=0
  out=$(fleet_ssh "$HOST" 'scontrol show nodes --json' 2> "$errf") || rc=$?
  if (( rc == 255 )); then
    last="ssh to $HOST failed: $(tr '\n' ' ' < "$errf" | sed 's/ $//' | cut -c1-200)"; verdict=2
  elif (( rc != 0 )); then
    last="scontrol on $HOST exit $rc: $(tr '\n' ' ' < "$errf" | sed 's/ $//' | cut -c1-200)"; verdict=2
  else
    verdict=0
    last=$(evaluate <<< "$out") || verdict=$?
  fi
  elapsed=$(( SECONDS - start ))
  if (( verdict == 0 )); then
    echo "SLURM: all nodes usable after ${elapsed}s: $last"
    exit 0
  fi
  if (( elapsed + INTERVAL > WAIT )); then
    if (( verdict == 1 )); then
      echo "SLURM: FAILED: nodes not usable after ${elapsed}s: $last"
      exit 1
    fi
    echo "SLURM: could not check within ${elapsed}s: $last"
    exit 2
  fi
  sleep "$INTERVAL"
done
