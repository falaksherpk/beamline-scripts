#!/usr/bin/env bash
set -euo pipefail

export LIBVIRT_DEFAULT_URI="qemu:///system"
cd "$(dirname "${BASH_SOURCE[0]}")"
source fleet.conf

FORCE=false
ONLY=""
SKIP=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --only=*) ONLY="${arg#--only=}" ;;
    --skip=*) SKIP="${arg#--skip=}" ;;
    *) echo "Unknown argument: $arg (supported: --force, --only=<list>, --skip=<list>)" >&2; exit 1 ;;
  esac
done
if [[ -n "$ONLY" && -n "$SKIP" ]]; then
  echo "ERROR: --only and --skip are mutually exclusive" >&2
  exit 1
fi

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

# --- SLURM drain: only relevant if hpc-ctl.beamline is in this run's scope ---
if printf '%s\n' "${FLEET_HOSTS[@]}" | grep -qx "hpc-ctl.beamline"; then
  echo "=== SLURM: checking for running jobs on HPC compute nodes (via hpc-ctl.beamline) ==="
  RUNNING_JOBS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
       "$SSH_USER@hpc-ctl.beamline" "squeue -h -w hpc-c1.beamline,hpc-gpu.beamline" 2>/dev/null || true)

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
  if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
       "$SSH_USER@hpc-ctl.beamline" '
         set -e
         for node in hpc-c1.beamline hpc-gpu.beamline; do
           sudo scontrol update NodeName="$node" State=DOWN Reason="Scheduled evening shutdown"
         done
       '; then
    echo "hpc-c1.beamline, hpc-gpu.beamline marked DOWN (scheduled shutdown)"
  else
    echo "WARNING: could not reach hpc-ctl.beamline to drain SLURM — proceeding with VM shutdown anyway"
  fi
else
  echo "=== SLURM drain skipped (hpc-ctl.beamline not in this run's scope) ==="
fi

echo ""
echo "=== Requesting graceful ACPI shutdown for selected beamline VMs (staggered, 10s apart) ==="
for vm in "${FLEET_HOSTS[@]}"; do
  echo "Shutting down $vm..."
  virsh shutdown "$vm" 2>/dev/null || echo "WARNING: $vm not found or already off"
  sleep 2
done

echo ""
echo "=== Waiting for clean power-off (polling, up to 4 min) ==="
for i in $(seq 1 24); do
  remaining=""
  for vm in "${FLEET_HOSTS[@]}"; do
    state=$(virsh domstate "$vm" 2>/dev/null || echo "shut off")
    [ "$state" != "shut off" ] && remaining="$remaining $vm"
  done
  if [ -z "$remaining" ]; then
    echo "All selected beamline VMs are shut off."
    break
  fi
  sleep 5
done

echo ""
echo "=== Final state ==="
virsh list --all

echo ""
echo "=== Force-stopping anything still running (should be empty) ==="
for vm in "${FLEET_HOSTS[@]}"; do
  state=$(virsh domstate "$vm" 2>/dev/null || echo "shut off")
  if [ "$state" != "shut off" ]; then
    echo "WARNING: $vm did not shut down cleanly — forcing off"
    virsh destroy "$vm"
  fi
done
