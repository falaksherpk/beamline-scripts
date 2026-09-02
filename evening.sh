#!/usr/bin/env bash
set -euo pipefail

export LIBVIRT_DEFAULT_URI="qemu:///system"

echo "=== SLURM: checking for running jobs and draining HPC compute nodes (via hpc-ctl.beamline) ==="
# Runs BEFORE any VM shutdown below — hpc-ctl must still be up and reachable to
# talk to slurmctld. Marks hpc-c1/hpc-gpu DOWN with an explicit reason so
# slurmctld's state reflects an INTENTIONAL shutdown, not a mystery.
# NOTE: this does NOT prevent tomorrow's "Node unexpectedly rebooted" flag —
# that's triggered by the guest reporting a new boot time on next start, which
# happens regardless of how gracefully it was shut down. morning.sh's resume
# step is still required either way; this is a courtesy/safety check, not a
# substitute for it.
if ssh -i ~/.ssh/beamline_vms -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
     falak@hpc-ctl.beamline '
       set -e
       running=$(squeue -h -w hpc-c1.beamline,hpc-gpu.beamline)
       if [ -n "$running" ]; then
         echo "WARNING: jobs are still RUNNING on the HPC nodes — shutting down now will kill them:"
         echo "$running"
       else
         echo "no running jobs on hpc-c1.beamline/hpc-gpu.beamline — safe to proceed"
       fi
       for node in hpc-c1.beamline hpc-gpu.beamline; do
         sudo scontrol update NodeName="$node" State=DOWN Reason="Scheduled evening shutdown"
       done
     '; then
  echo "hpc-c1.beamline, hpc-gpu.beamline marked DOWN (scheduled shutdown)"
else
  echo "WARNING: could not reach hpc-ctl.beamline to check/drain SLURM — proceeding with VM shutdown anyway"
fi

echo ""
echo "=== Requesting graceful ACPI shutdown for all beamline VMs (staggered, 10s apart) ==="
for vm in $(virsh list --name | grep beamline); do
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
