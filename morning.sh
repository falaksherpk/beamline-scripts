#!/usr/bin/env bash
set -euo pipefail

export LIBVIRT_DEFAULT_URI="qemu:///system"

# Fleet hostnames, in the same order as /etc/hosts on beamlinehost.
# Resolution works here because beamlinehost's OWN local Ansible control
# plane (beamlinehost-ansible, separate from lab-ansible on admin.beamline)
# deploys this same fleet roster to beamlinehost's /etc/hosts too — confirmed
# 13 Aug 2026 (`sudo cat /etc/hosts` lists all 13 *.beamline names against
# their static lab0 IPs). If that role is ever removed, these names stop
# resolving and every ssh call below breaks — worth remembering why this works.
FLEET_HOSTS=(
  admin.beamline gitlab.beamline pkg.beamline puppet.beamline
  k8cp.beamline k8w1.beamline k8w2.beamline
  tango-db.beamline tango-ds.beamline obs.beamline
  hpc-ctl.beamline hpc-c1.beamline hpc-gpu.beamline
)

echo "=== Starting all beamline VMs (staggered, 10s apart) ==="
for vm in $(virsh list --all --name | grep beamline); do
  state=$(virsh domstate "$vm")
  if [ "$state" = "shut off" ]; then
    echo "Starting $vm..."
    virsh start "$vm"
    sleep 5
  else
    echo "$vm already $state, skipping"
  fi
done

echo ""
echo "=== Waiting for each host's SSH to come up (up to 4 min per host) ==="
wait_for_ssh() {
  local host=$1
  for i in $(seq 1 48); do
    if ssh -i ~/.ssh/beamline_vms -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
         -o BatchMode=yes falak@"$host" true 2>/dev/null; then
      return 0
    fi
    sleep 5
  done
  return 1
}

for host in "${FLEET_HOSTS[@]}"; do
  echo -n "$host: waiting... "
  if wait_for_ssh "$host"; then
    echo "ready"
  else
    echo "NOT READY after 4 min — investigate this host separately"
  fi
done

echo ""
echo "=== Fleet state ==="
virsh list --all

echo ""
echo "=== Per-VM hostname / interface / internet check ==="
for host in "${FLEET_HOSTS[@]}"; do
  echo "=== $host ==="
  ssh -i ~/.ssh/beamline_vms -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    falak@"$host" "hostname; ip a | grep -E 'lab0|nat0' | grep inet; \
    ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && echo 'internet:OK' || echo 'internet:FAIL'" 2>&1 || true
done

echo ""
echo "=== SLURM: resuming HPC compute nodes after reboot (via hpc-ctl.beamline) ==="
# A full VM reboot always gives slurmd a new boot time, which slurmctld reports as
# "Node unexpectedly rebooted" and marks DOWN (ReturnToService=0, left at its safe
# default — see beamlinehost RUNBOOK). Resuming here is idempotent: harmless if a
# node is already idle, so this always runs rather than trying to detect DOWN first.
if ssh -i ~/.ssh/beamline_vms -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
     falak@hpc-ctl.beamline '
       set -e
       for node in hpc-c1.beamline hpc-gpu.beamline; do
         sudo scontrol update NodeName="$node" State=RESUME
       done
     '; then
  echo "resume issued for hpc-c1.beamline, hpc-gpu.beamline"
else
  echo "WARNING: SLURM node resume failed — check manually: ssh hpc-ctl.beamline, then scontrol show node"
fi

echo ""
echo "=== SLURM: waiting for hpc-c1/hpc-gpu to report responding (up to 20s) ==="
# RESUME clears the DOWN state immediately, but a node can still show idle*
# (NOT_RESPONDING) for a few seconds if slurmd hasn't finished re-registering
# with slurmctld yet — SSH coming up doesn't guarantee slurmd already has,
# since they're independent services. Poll the real state instead of guessing
# a fixed delay, same idiom as wait_for_ssh above.
for i in $(seq 1 4); do
  states=$(ssh -i ~/.ssh/beamline_vms -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    falak@hpc-ctl.beamline "sinfo -h -N -o '%N %T' -n hpc-c1.beamline,hpc-gpu.beamline" 2>/dev/null || true)
  if [ -n "$states" ] && ! echo "$states" | grep -q '\*'; then
    echo "both nodes responding"
    break
  fi
  sleep 5
done

echo ""
echo "=== SLURM cluster state (from hpc-ctl.beamline) ==="
ssh -i ~/.ssh/beamline_vms -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
  falak@hpc-ctl.beamline 'sinfo' || echo "WARNING: could not reach hpc-ctl.beamline for sinfo"
