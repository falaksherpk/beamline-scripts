#!/usr/bin/env bash
set -euo pipefail

export LIBVIRT_DEFAULT_URI="qemu:///system"
cd "$(dirname "${BASH_SOURCE[0]}")"
source fleet.conf

# --- Argument parsing: --only=<group,host,...> / --skip=<group,host,...> ---
ONLY=""
SKIP=""
for arg in "$@"; do
  case "$arg" in
    --only=*) ONLY="${arg#--only=}" ;;
    --skip=*) SKIP="${arg#--skip=}" ;;
    *) echo "Unknown argument: $arg (supported: --only=<list>, --skip=<list>)" >&2; exit 1 ;;
  esac
done
if [[ -n "$ONLY" && -n "$SKIP" ]]; then
  echo "ERROR: --only and --skip are mutually exclusive" >&2
  exit 1
fi

# Expand a comma-separated list of group-names-or-hostnames into a
# space-separated, deduplicated list of real hostnames.
expand_list() {
  local list="$1" item hosts=""
  IFS=',' read -ra items <<< "$list"
  for item in "${items[@]}"; do
    if [[ -n "${FLEET_GROUPS[$item]:-}" || -n "${FLEET_CHILDREN[$item]:-}" ]]; then
      hosts="$hosts $(resolve_group "$item")"
    else
      hosts="$hosts $item"
    fi
  done
  echo "$hosts" | tr ' ' '\n' | grep -v '^$' | sort -u
}

if [[ -n "$ONLY" ]]; then
  FLEET_HOSTS=($(expand_list "$ONLY"))
elif [[ -n "$SKIP" ]]; then
  skip_hosts=$(expand_list "$SKIP")
  FLEET_HOSTS=($(comm -23 <(all_fleet_hosts) <(echo "$skip_hosts")))
else
  FLEET_HOSTS=($(all_fleet_hosts))
fi

echo "=== Target hosts for this run: ${FLEET_HOSTS[*]} ==="
echo ""

echo "=== Starting selected beamline VMs (staggered, 10s apart) ==="
for vm in "${FLEET_HOSTS[@]}"; do
  state=$(virsh domstate "$vm" 2>/dev/null || echo "unknown")
  if [ "$state" = "shut off" ]; then
    echo "Starting $vm..."
    virsh start "$vm"
    sleep 5
  elif [ "$state" = "unknown" ]; then
    echo "WARNING: $vm not found by virsh domstate -- check hostname/domain name match"
  else
    echo "$vm already $state, skipping"
  fi
done

echo ""
echo "=== Waiting for each host's SSH to come up (up to 4 min per host) ==="
wait_for_ssh() {
  local host=$1
  for i in $(seq 1 48); do
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
         -o BatchMode=yes "$SSH_USER@$host" true 2>/dev/null; then
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
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    "$SSH_USER@$host" "hostname; ip a | grep -E 'lab0|nat0' | grep inet; \
    ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && echo 'internet:OK' || echo 'internet:FAIL'" 2>&1 || true
done

# --- SLURM resume: only relevant if hpc-ctl.beamline is in this run's scope ---
if printf '%s\n' "${FLEET_HOSTS[@]}" | grep -qx "hpc-ctl.beamline"; then
  echo ""
  echo "=== SLURM: resuming HPC compute nodes after reboot (via hpc-ctl.beamline) ==="
  # A full VM reboot always gives slurmd a new boot time, which slurmctld reports as
  # "Node unexpectedly rebooted" and marks DOWN (ReturnToService=0, left at its safe
  # default). Resuming here is idempotent: harmless if a node is already idle, so
  # this always runs rather than trying to detect DOWN first.
  if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
       "$SSH_USER@hpc-ctl.beamline" '
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
  for i in $(seq 1 4); do
    states=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      "$SSH_USER@hpc-ctl.beamline" "sinfo -h -N -o '%N %T' -n hpc-c1.beamline,hpc-gpu.beamline" 2>/dev/null || true)
    if [ -n "$states" ] && ! echo "$states" | grep -q '\*'; then
      echo "both nodes responding"
      break
    fi
    sleep 5
  done

  echo ""
  echo "=== SLURM cluster state (from hpc-ctl.beamline) ==="
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    "$SSH_USER@hpc-ctl.beamline" 'sinfo' || echo "WARNING: could not reach hpc-ctl.beamline for sinfo"
else
  echo ""
  echo "=== SLURM resume skipped (hpc-ctl.beamline not in this run's scope) ==="
fi
