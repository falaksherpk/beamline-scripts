#!/usr/bin/env bash
# Pre-shutdown hook for hpc-ctl.beamline (handbook Ch18; contract: hooks/README.md).
# Asks slurmctld for its jobs: any job that is not purely PENDING (running,
# completing, configuring, suspended, ...) would be killed by the shutdown, so the
# hook reports it and exits 1 -- fleet-down.sh then aborts unless --force is given.
# Pending jobs are listed but don't block: they survive in slurmctld's saved state.
# The hook changes nothing (no drain: the nodes come back idle after a cold boot).
# Exit 0 = safe, 1 = jobs would be killed, 2 = could not check.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-down.sh}/fleet-lib.sh"
HOST=${FLEET_HOST:?run from fleet-down.sh}

# stdout must stay pure JSON, so ssh's and squeue's stderr go to a file of their own.
errf=$(mktemp) || { echo "SLURM: could not check: mktemp failed"; exit 2; }
trap 'rm -f "$errf"' EXIT
rc=0
out=$(fleet_ssh "$HOST" 'squeue --json' 2> "$errf") || rc=$?
err=$(tr '\n' ' ' < "$errf" | sed 's/ $//' | cut -c1-300)
if (( rc == 255 )); then
  echo "SLURM: could not check: ssh to $HOST failed: $err"
  exit 2
elif (( rc != 0 )); then
  echo "SLURM: could not check: squeue --json on $HOST exit $rc: $err"
  exit 2
fi

python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError as e:
    print("SLURM: could not check: squeue --json output is not JSON: %s" % e)
    sys.exit(2)
if d.get("errors"):
    print("SLURM: could not check: squeue reported errors: %s" % str(d["errors"])[:200])
    sys.exit(2)
jobs = d.get("jobs", [])
active, pending = [], []
for j in jobs:
    flags = j.get("job_state") or []
    line = "job %s %s (%s) %s on %s" % (j.get("job_id"), j.get("name"), j.get("user_name"),
                                         "+".join(flags) or "no state", j.get("nodes") or "-")
    (pending if flags == ["PENDING"] else active).append(line)
for line in pending:
    print("SLURM: pending, kept across the shutdown: " + line)
if active:
    for line in active:
        print("SLURM: would be killed by the shutdown: " + line)
    print("SLURM: NOT safe: %d job(s) not pending; drain or cancel them, or use --force" % len(active))
    sys.exit(1)
print("SLURM: safe: no running jobs (%d pending)" % len(pending))
sys.exit(0)
' <<< "$out"
