#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<'USAGE'
Usage: fleet-up.sh [--only=<list>] [--skip=<list>] [--with-healthcheck] [--dry-run]

Start the beamline VM fleet (or a subset), wait for each host's SSH to
come up, run per-host checks, and optionally chain into fleet-check.sh.

Options:
  --only=<group,host,...>   Only start the listed groups/hosts (comma-separated)
  --skip=<group,host,...>   Start everything except the listed groups/hosts
  --with-healthcheck        Run fleet-check.sh after the boot sequence completes
  --dry-run                 Print what would happen; no VMs are started, no hooks run
  -h, --help                Show this help message and exit

Examples:
  fleet-up.sh
  fleet-up.sh --only=control,gitlab,tango
  fleet-up.sh --skip=hpc --dry-run
  fleet-up.sh --with-healthcheck

--only and --skip are mutually exclusive. Group/host names are defined in fleet.conf.
Exit code: 0 if every targeted host became ready (and, with --with-healthcheck, every
check passed); 1 otherwise.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) print_usage; exit 0 ;;
  esac
done

export LIBVIRT_DEFAULT_URI="qemu:///system"
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./fleet.conf
source fleet.conf

# Prevent two instances of this script running concurrently against
# the same fleet -- a stray cron job overlapping a manual run, or two
# people running fleet-up.sh/fleet-down.sh at once, could otherwise race.
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
WITH_HEALTHCHECK=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --only=*) ONLY="${arg#--only=}" ;;
    --skip=*) SKIP="${arg#--skip=}" ;;
    --with-healthcheck) WITH_HEALTHCHECK=true ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown argument: $arg (supported: --only=<list>, --skip=<list>, --with-healthcheck, --dry-run, --help)" >&2; exit 1 ;;
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
    elif [[ "$item" != *.* ]] && all_fleet_hosts | grep -qx "${item}.beamline"; then
      # Bare short name (e.g. "admin", "pkg") that isn't a group name but
      # matches a real host once .beamline is appended. Real usability gap
      # found by actually running this: the group for admin.beamline is
      # named "control" (matching inventory.ini's functional-role naming),
      # not "admin" -- typing --only=admin silently fell through to being
      # treated as a literal, unresolvable hostname instead.
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

echo "=== Starting selected beamline VMs (staggered, 10s apart) ==="
for vm in "${FLEET_HOSTS[@]}"; do
  state=$(virsh domstate "$vm" 2>/dev/null || echo "unknown")
  if [ "$state" = "shut off" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo "[DRY RUN] would start $vm"
    else
      echo "Starting $vm..."
      virsh start "$vm"
      sleep 5
    fi
  elif [ "$state" = "unknown" ]; then
    echo "WARNING: $vm not found by virsh domstate -- check hostname/domain name match"
  else
    echo "$vm already $state, skipping"
  fi
done

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "=== DRY RUN: skipping SSH-readiness wait, interface checks, hooks, and healthcheck ==="
  echo "=== DRY RUN complete -- no actions were taken ==="
  exit 0
fi

echo ""
echo "=== Waiting for each host's SSH to come up (up to 4 min per host, in parallel) ==="
wait_for_ssh() {
  # Disable the inherited EXIT trap inside this backgrounded subshell --
  # without this, the FIRST background job to finish fires the parent's
  # "rm -rf $SSH_RESULT_DIR" trap early (traps are inherited by subshells),
  # deleting the shared result directory out from under every other host
  # still running, and silently truncating the rest of the parent script.
  # Found by actually running this: the log file cut off mid-run with no
  # error, right after the first "echo not_ready"/"echo ready" + rm -rf.
  trap - EXIT

  local host=$1
  local result_file=$2
  for _ in $(seq 1 48); do
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
         -o BatchMode=yes "$SSH_USER@$host" true 2>/dev/null; then
      echo "ready" > "$result_file"
      return 0
    fi
    sleep 5
  done
  echo "not_ready" > "$result_file"
  return 1
}

SSH_RESULT_DIR=$(mktemp -d)
trap 'rm -rf "$SSH_RESULT_DIR"' EXIT

SSH_WAIT_PIDS=()
for host in "${FLEET_HOSTS[@]}"; do
  wait_for_ssh "$host" "$SSH_RESULT_DIR/$host" &
  SSH_WAIT_PIDS+=($!)
done
# Wait only on the specific SSH-check PIDs -- NOT a bare `wait`, which would
# also block on the tee subshell from the exec > >(tee ...) logging redirect
# above, since that subshell is technically a background job too and never
# exits on its own (only when the script's own stdout closes at script exit,
# which can't happen while wait is still blocking on it -- a real deadlock,
# found by actually running this).
for pid in "${SSH_WAIT_PIDS[@]}"; do
  # || true: we only need this to block until the job finishes, not its
  # exit status (already captured via the per-host result file below) --
  # under set -e, a bare `wait $pid` on a failed background job would
  # otherwise kill the whole script silently the instant the FIRST failing
  # host's wait call returns. Found by actually running this: the script
  # died with no error, right after the SSH-wait section, at exactly the
  # timeout of the one genuinely failing host.
  wait "$pid" || true
done

READY_HOSTS=()
NOT_READY_HOSTS=()
for host in "${FLEET_HOSTS[@]}"; do
  result=$(cat "$SSH_RESULT_DIR/$host" 2>/dev/null || echo "not_ready")
  if [ "$result" = "ready" ]; then
    echo "$host: ready"
    READY_HOSTS+=("$host")
  else
    echo "$host: NOT READY after 4 min — investigate this host separately"
    NOT_READY_HOSTS+=("$host")
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

echo ""
echo "=== Summary ==="
echo "Ready (${#READY_HOSTS[@]}/${#FLEET_HOSTS[@]}): ${READY_HOSTS[*]:-none}"
EXIT_CODE=0
if [ "${#NOT_READY_HOSTS[@]}" -gt 0 ]; then
  echo "NOT ready (${#NOT_READY_HOSTS[@]}/${#FLEET_HOSTS[@]}): ${NOT_READY_HOSTS[*]}"
  EXIT_CODE=1
fi

if [ "$WITH_HEALTHCHECK" = true ]; then
  echo ""
  echo "=== Running fleet-check.sh (--with-healthcheck given) ==="
  if ! "$(dirname "${BASH_SOURCE[0]}")/fleet-check.sh"; then
    echo "WARNING: fleet-check.sh reported one or more failures (see above)"
    EXIT_CODE=1
  fi
fi

exit "$EXIT_CODE"
