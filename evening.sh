#!/usr/bin/env bash
set -euo pipefail

export LIBVIRT_DEFAULT_URI="qemu:///system"

FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    *) echo "Unknown argument: $arg (only --force is supported)" >&2; exit 1 ;;
  esac
done

echo "=== SLURM: checking for running jobs on HPC compute nodes (via hpc-ctl.beamline) ==="
# Query first, decide, THEN drain -- separated into two SSH calls (was one)
# so the parent script can see the job status and actually act on it,
# instead of only printing a warning and shutting down regardless.
RUNNING_JOBS=$(ssh -i ~/.ssh/beamline_vms -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
     falak@hpc-ctl.beamline "squeue -h -w hpc-c1.beamline,hpc-gpu.beamline" 2>/dev/null || true)

if [ -n "$RUNNING_JOBS" ]; then
  echo "WARNING: jobs are still RUNNING on the HPC nodes:"
  echo "$RUNNING_JOBS"
  if [ "$FORCE" = false ]; then
    echo ""
    echo "ABORTING: shutting down now would kill these jobs. Re-run with --force to proceed anyway."
    exit 1
  fi
  echo "--force given: proceeding with shutdown despite running jobs."
else
  echo "no running jobs on hpc-c1.beamline/hpc-gpu.beamline — safe to proceed"
fi

echo ""
echo "=== SLURM: draining HPC compute nodes (via hpc-ctl.beamline) ==="
# NOTE: this does NOT prevent tomorrow's "Node unexpectedly rebooted" flag --
# that's triggered by the guest reporting a new boot time on next start,
# regardless of how gracefully it was shut down. morning.sh's resume step
# is still required either way; this is a courtesy/safety marker, not a
# substitute for it.
if ssh -i ~/.ssh/beamline_vms -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
     falak@hpc-ctl.beamline '
       set -e
       for node in hpc-c1.beamline hpc-gpu.beamline; do
         sudo scontrol update NodeName="$node" State=DOWN Reason="Scheduled evening shutdown"
       done
     '; then
  echo "hpc-c1.beamline, hpc-gpu.beamline marked DOWN (scheduled shutdown)"
else
  echo "WARNING: could not reach hpc-ctl.beamline to drain SLURM — proceeding with VM shutdown anyway"
fi

echo ""
echo "=== Requesting graceful ACPI shutdown for all beamline VMs (staggered, 10s apart) ==="
for vm in $(virsh list --name | grep beamline || true); do
  echo "Shutting down $vm..."
  virsh shutdown "$vm"
  sleep 2
done

echo ""
echo "=== Waiting for clean power-off (polling, up to 4 min) ==="
for i in $(seq 1 24); do
  remaining=$(virsh list --name | grep beamline || true)
  if [ -z "$remaining" ]; then
    echo "All beamline VMs are shut off."
    break
  fi
  sleep 5
done

echo ""
echo "=== Final state ==="
virsh list --all

echo ""
echo "=== Force-stopping anything still running (should be empty) ==="
for vm in $(virsh list --name | grep beamline || true); do
  echo "WARNING: $vm did not shut down cleanly — forcing off"
  virsh destroy "$vm"
done
