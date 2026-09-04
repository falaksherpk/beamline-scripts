#!/usr/bin/env bash
set -euo pipefail
# Called by fleet-up.sh, once, only if hpc-ctl.beamline is in this run's scope.
# Resumes SLURM compute nodes after a VM reboot marks them DOWN.
#
# Non-fatal by design: fleet-up.sh continues regardless of this hook's exit
# code -- a SLURM hiccup shouldn't block the rest of the fleet boot.

HOST="hpc-ctl.beamline"

echo "=== [$HOST hook] SLURM: resuming HPC compute nodes after reboot ==="
# A full VM reboot always gives slurmd a new boot time, which slurmctld reports
# as "Node unexpectedly rebooted" and marks DOWN (ReturnToService=0, left at
# its safe default). Resuming here is idempotent: harmless if a node is
# already idle, so this always runs rather than trying to detect DOWN first.
if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
     "$SSH_USER@$HOST" '
       set -e
       for node in hpc-c1.beamline hpc-gpu.beamline; do
         sudo scontrol update NodeName="$node" State=RESUME
       done
     '; then
  echo "[$HOST hook] resume issued for hpc-c1.beamline, hpc-gpu.beamline"
else
  echo "[$HOST hook] WARNING: SLURM node resume failed — check manually: ssh $HOST, then scontrol show node"
fi

echo ""
echo "=== [$HOST hook] SLURM: waiting for hpc-c1/hpc-gpu to report responding (up to 20s) ==="
for _ in $(seq 1 4); do
  states=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    "$SSH_USER@$HOST" "sinfo -h -N -o '%N %T' -n hpc-c1.beamline,hpc-gpu.beamline" 2>/dev/null || true)
  if [ -n "$states" ] && ! echo "$states" | grep -q '\*'; then
    echo "[$HOST hook] both nodes responding"
    break
  fi
  sleep 5
done

echo ""
echo "=== [$HOST hook] SLURM cluster state ==="
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
  "$SSH_USER@$HOST" 'sinfo' || echo "[$HOST hook] WARNING: could not reach $HOST for sinfo"
