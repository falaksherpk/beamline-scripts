#!/usr/bin/env bash
set -euo pipefail

export LIBVIRT_DEFAULT_URI="qemu:///system"
cd "$(dirname "${BASH_SOURCE[0]}")"
source fleet.conf

# Prevent two instances of this script running concurrently against
# the same fleet -- a stray cron job overlapping a manual run, or two
# people running morning.sh/evening.sh at once, could otherwise race.
LOCKFILE="/tmp/beamline-scripts-$(basename "$0").lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  echo "ERROR: another instance of $(basename "$0") is already running (lock: $LOCKFILE)" >&2
  exit 1
fi

# Persistent, timestamped log of this run -- terminal output is
# unchanged (everything is still shown live via tee), but a copy
# also lands here for later review, independent of scrollback.
LOG_DIR="$(dirname "${BASH_SOURCE[0]}")/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Logging this run to $LOG_FILE ==="

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

# --- Post-boot hooks: run hooks/<host>.post-boot.sh for each host in scope,
# if it exists. Lets host-specific startup behavior (e.g. today: SLURM
# resume on hpc-ctl.beamline) live outside this script entirely, so this
# script has no built-in knowledge of any particular group's needs.
echo ""
echo "=== Post-boot hooks ==="
for host in "${FLEET_HOSTS[@]}"; do
  hook="$(dirname "${BASH_SOURCE[0]}")/hooks/${host}.post-boot.sh"
  if [ -x "$hook" ]; then
    echo "--- running post-boot hook for $host ---"
    SSH_KEY="$SSH_KEY" SSH_USER="$SSH_USER" "$hook" || \
      echo "WARNING: post-boot hook for $host exited non-zero (non-fatal, continuing)"
  fi
done
