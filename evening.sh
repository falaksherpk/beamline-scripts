#!/usr/bin/env bash
set -euo pipefail

export LIBVIRT_DEFAULT_URI="qemu:///system"
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./fleet.conf
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
    elif [[ "$item" != *.* ]] && all_fleet_hosts | grep -qx "${item}.beamline"; then
      # Bare short name (e.g. "admin", "pkg") that isn't a group name but
      # matches a real host once .beamline is appended -- same fix as
      # morning.sh, found the same way (--only=admin silently treated as
      # an unresolvable literal hostname instead of admin.beamline).
      hosts="$hosts ${item}.beamline"
    else
      hosts="$hosts $item"
    fi
  done
  echo "$hosts" | tr ' ' '\n' | grep -v '^$' | sort -u
}

if [[ -n "$ONLY" ]]; then
  mapfile -t FLEET_HOSTS < <(expand_list "$ONLY")
elif [[ -n "$SKIP" ]]; then
  skip_hosts=$(expand_list "$SKIP")
  mapfile -t FLEET_HOSTS < <(comm -23 <(all_fleet_hosts) <(echo "$skip_hosts"))
else
  mapfile -t FLEET_HOSTS < <(all_fleet_hosts)
fi

echo "=== Target hosts for this run: ${FLEET_HOSTS[*]} ==="
echo ""

# --- Pre-shutdown hooks: run hooks/<host>.pre-shutdown.sh for each host in
# scope, if it exists, BEFORE any VM shutdown. Unlike morning.sh's post-boot
# hooks, a nonzero exit here ABORTS the whole run -- this is where a hook
# gets to say "not safe to proceed" (e.g. today: SLURM jobs still running).
echo "=== Pre-shutdown hooks ==="
for host in "${FLEET_HOSTS[@]}"; do
  hook="$(dirname "${BASH_SOURCE[0]}")/hooks/${host}.pre-shutdown.sh"
  if [ -x "$hook" ]; then
    echo "--- running pre-shutdown hook for $host ---"
    if ! SSH_KEY="$SSH_KEY" SSH_USER="$SSH_USER" FORCE="$FORCE" "$hook"; then
      echo "ABORTING: pre-shutdown hook for $host exited non-zero"
      exit 1
    fi
  fi
done

echo ""
echo "=== Requesting graceful ACPI shutdown for selected beamline VMs (staggered, 10s apart) ==="
for vm in "${FLEET_HOSTS[@]}"; do
  echo "Shutting down $vm..."
  virsh shutdown "$vm" 2>/dev/null || echo "WARNING: $vm not found or already off"
  sleep 2
done

echo ""
echo "=== Waiting for clean power-off (polling, up to 4 min) ==="
for _ in $(seq 1 24); do
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
