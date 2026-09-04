#!/usr/bin/env bash
set -euo pipefail
# Called by fleet-down.sh, once, only if hpc-ctl.beamline is in this run's scope,
# BEFORE any VM shutdown happens.
#
# Exit code contract: 0 = safe to proceed, nonzero = fleet-down.sh aborts the
# entire run. $FORCE is exported by fleet-down.sh ("true"/"false").

HOST="hpc-ctl.beamline"

echo "=== [$HOST hook] SLURM: checking for running jobs on HPC compute nodes ==="
RUNNING_JOBS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
     "$SSH_USER@$HOST" "squeue -h -w hpc-c1.beamline,hpc-gpu.beamline" 2>/dev/null || true)

if [ -n "$RUNNING_JOBS" ]; then
  echo "[$HOST hook] WARNING: jobs are still RUNNING on the HPC nodes:"
  echo "$RUNNING_JOBS"
  if [ "${FORCE:-false}" != "true" ]; then
    echo ""
    echo "[$HOST hook] ABORTING: shutting down now would kill these jobs. Re-run fleet-down.sh with --force to proceed anyway."
    exit 1
  fi
  echo "[$HOST hook] --force given: proceeding with shutdown despite running jobs."
else
  echo "[$HOST hook] no running jobs on hpc-c1.beamline/hpc-gpu.beamline — safe to proceed"
fi

echo ""
echo "=== [$HOST hook] SLURM: draining HPC compute nodes ==="
# NOTE: this does NOT prevent tomorrow's "Node unexpectedly rebooted" flag --
# that's triggered by the guest reporting a new boot time on next start,
# regardless of how gracefully it was shut down. The post-boot hook's resume
# step is still required either way; this is a courtesy/safety marker, not a
# substitute for it.
if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
     "$SSH_USER@$HOST" '
       set -e
       for node in hpc-c1.beamline hpc-gpu.beamline; do
         sudo scontrol update NodeName="$node" State=DOWN Reason="Scheduled fleet shutdown"
       done
     '; then
  echo "[$HOST hook] hpc-c1.beamline, hpc-gpu.beamline marked DOWN (scheduled shutdown)"
else
  echo "[$HOST hook] WARNING: could not reach $HOST to drain SLURM — proceeding with VM shutdown anyway"
fi

exit 0
