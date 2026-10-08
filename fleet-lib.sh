# fleet-lib.sh -- shared code for fleet-up.sh, fleet-down.sh, fleet-check.sh
# and hooks. Sourced, never executed. Reads its data from fleet.conf.
# shellcheck shell=bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "fleet-lib.sh is a library: source it, don't run it" >&2
  exit 2
fi
if [[ -n "${FLEET_LIB_LOADED:-}" ]]; then
  return 0
fi
FLEET_LIB_LOADED=1

FLEET_DIR="$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")"
# shellcheck disable=SC2034  # exit codes for the scripts that source this
FLEET_EXIT_OK=0 FLEET_EXIT_FAIL=1 FLEET_EXIT_USAGE=2

# shellcheck source=./fleet.conf
source "$FLEET_DIR/fleet.conf"
: "${LIBVIRT_DEFAULT_URI:=qemu:///system}"
export LIBVIRT_DEFAULT_URI FLEET_DIR

# --- Output -----------------------------------------------------------------
fleet_info()    { printf '%s\n' "$*"; }
fleet_warn()    { printf 'WARNING: %s\n' "$*" >&2; }
fleet_error()   { printf 'ERROR: %s\n' "$*" >&2; }
fleet_section() { printf '\n=== %s ===\n' "$*"; }
fleet_elapsed() { printf '%dm%02ds' $((SECONDS / 60)) $((SECONDS % 60)); }

# --- Configuration check: runs when the library is sourced ------------------
# Every host in FLEET_GROUPS appears in exactly one tier and vice versa;
# timings are whole numbers; host key checking is "yes" or "accept-new".
fleet_validate_config() {
  local h t v bad=0
  local -a hosts
  local -A in_groups=() tier_count=()

  read -ra hosts <<< "${FLEET_GROUPS[*]}"
  for h in "${hosts[@]}"; do in_groups[$h]=1; done
  for t in "${FLEET_TIERS[@]}"; do
    read -ra hosts <<< "$t"
    for h in "${hosts[@]}"; do tier_count[$h]=$(( ${tier_count[$h]:-0} + 1 )); done
  done
  for h in "${!in_groups[@]}"; do
    if [[ ${tier_count[$h]:-0} -ne 1 ]]; then
      fleet_error "fleet.conf: $h is in ${tier_count[$h]:-0} tiers (must be exactly 1)"; bad=1
    fi
  done
  for h in "${!tier_count[@]}"; do
    if [[ ! -v in_groups[$h] ]]; then
      fleet_error "fleet.conf: $h is in FLEET_TIERS but in no group"; bad=1
    fi
  done
  for v in FLEET_START_STAGGER FLEET_SHUTDOWN_STAGGER FLEET_SSH_WAIT_TIMEOUT \
           FLEET_SHUTDOWN_TIMEOUT FLEET_HOOK_TIMEOUT FLEET_POLL_INTERVAL \
           FLEET_SSH_CONNECT_TIMEOUT FLEET_CHECK_TIMEOUT FLEET_SLOW_CHECK_TIMEOUT; do
    if [[ ! ${!v:-} =~ ^[0-9]+$ ]]; then
      fleet_error "fleet.conf: $v='${!v:-}' is not a whole number of seconds"; bad=1
    fi
  done
  # Format only: whether each tag is a play tag of site.yml is checked by the
  # drift check itself, on admin.beamline, where site.yml lives.
  local -a skip_tags
  read -ra skip_tags <<< "${FLEET_DRIFT_SKIP_TAGS:-}"
  for h in "${skip_tags[@]}"; do
    if [[ ! $h =~ ^[A-Za-z0-9_]+$ ]]; then
      fleet_error "fleet.conf: FLEET_DRIFT_SKIP_TAGS has an invalid tag '$h'"; bad=1
    fi
  done
  case "$FLEET_SSH_HOST_KEY_CHECKING" in
    yes|accept-new) ;;
    *) fleet_error "fleet.conf: FLEET_SSH_HOST_KEY_CHECKING must be yes or accept-new"; bad=1 ;;
  esac
  return "$bad"
}

# --- Names and selection ----------------------------------------------------
# All hosts, one per line, in tier order.
fleet_all_hosts() {
  local t
  local -a hosts
  for t in "${FLEET_TIERS[@]}"; do
    read -ra hosts <<< "$t"
    printf '%s\n' "${hosts[@]}"
  done
}

# Hosts of a group or :children group, one per line. Non-zero if unknown.
fleet_resolve_group() {
  local name=$1 depth=${2:-0} child
  local -a items
  if (( depth > 10 )); then
    fleet_error "fleet.conf: group nesting deeper than 10 at '$name'"; return 1
  fi
  if [[ -v FLEET_GROUPS[$name] ]]; then
    read -ra items <<< "${FLEET_GROUPS[$name]}"
    printf '%s\n' "${items[@]}"
  elif [[ -v FLEET_CHILDREN[$name] ]]; then
    read -ra items <<< "${FLEET_CHILDREN[$name]}"
    for child in "${items[@]}"; do
      fleet_resolve_group "$child" $((depth + 1)) || return 1
    done
  else
    return 1
  fi
}

# "a,b,c" -> host names, one per line. Each item is a group, a :children
# group, a full host name or a bare one ("pkg" = pkg.$FLEET_DOMAIN).
# An unknown name is an error (status 2), never passed through.
fleet_expand_list() {
  local item h
  local -a items
  local -A known=()
  while read -r h; do known[$h]=1; done < <(fleet_all_hosts)
  IFS=',' read -ra items <<< "$1"
  for item in "${items[@]}"; do
    if [[ -z $item ]]; then
      continue
    elif [[ ! $item =~ ^[A-Za-z0-9_.-]+$ ]]; then
      fleet_error "invalid name '$item'"; return 2
    elif fleet_resolve_group "$item"; then
      continue
    elif [[ -v known[$item] ]]; then
      printf '%s\n' "$item"
    elif [[ -v known[$item.$FLEET_DOMAIN] ]]; then
      printf '%s\n' "$item.$FLEET_DOMAIN"
    else
      fleet_error "unknown group or host '$item' (names are defined in fleet.conf)"; return 2
    fi
  done
}

# fleet_select_hosts ONLY SKIP -> sets FLEET_HOSTS: unique, in tier order.
fleet_select_hosts() {
  local only=$1 skip=$2 listed h
  local -A pick=() drop=()
  if [[ -n $only && -n $skip ]]; then
    fleet_error "--only and --skip are mutually exclusive"; return 2
  fi
  if [[ -n $only ]]; then
    listed=$(fleet_expand_list "$only") || return 2
    while read -r h; do if [[ -n $h ]]; then pick[$h]=1; fi; done <<< "$listed"
  fi
  if [[ -n $skip ]]; then
    listed=$(fleet_expand_list "$skip") || return 2
    while read -r h; do if [[ -n $h ]]; then drop[$h]=1; fi; done <<< "$listed"
  fi
  FLEET_HOSTS=()
  while read -r h; do
    if [[ -n $only && ! -v pick[$h] ]]; then continue; fi
    if [[ -v drop[$h] ]]; then continue; fi
    FLEET_HOSTS+=("$h")
  done < <(fleet_all_hosts)
  if (( ${#FLEET_HOSTS[@]} == 0 )); then
    fleet_error "the selection matches no hosts"; return 2
  fi
}

# Selected hosts of tier N (0-based), one per line, in tier order.
fleet_tier_selected() {
  local h
  local -a hosts
  local -A sel=()
  for h in "${FLEET_HOSTS[@]}"; do sel[$h]=1; done
  read -ra hosts <<< "${FLEET_TIERS[$1]}"
  for h in "${hosts[@]}"; do
    if [[ -v sel[$h] ]]; then printf '%s\n' "$h"; fi
  done
}

# --- libvirt ----------------------------------------------------------------
# Every selected host must exist as a libvirt domain.
fleet_check_domains() {
  local h bad=0
  for h in "${FLEET_HOSTS[@]}"; do
    if ! virsh dominfo "$h" >/dev/null 2>&1; then
      fleet_error "no libvirt domain named '$h' (URI $LIBVIRT_DEFAULT_URI)"; bad=1
    fi
  done
  return "$bad"
}

# Prints the domain state ("running", "shut off", ...); non-zero if virsh fails.
fleet_domstate() {
  virsh domstate "$1" 2>/dev/null
}

# --- Locking and logging ----------------------------------------------------
# One lock for fleet-up.sh and fleet-down.sh together, at a fixed path
# (an environment-dependent path would give cron and a login shell
# different locks). fleet-check.sh only reads, and takes no lock.
fleet_lock() {
  mkdir -p "$FLEET_DIR/logs"
  FLEET_LOCK_FILE="$FLEET_DIR/logs/.fleet.lock"
  exec {FLEET_LOCK_FD}>>"$FLEET_LOCK_FILE"
  if ! flock -n "$FLEET_LOCK_FD"; then
    fleet_error "another fleet-up.sh/fleet-down.sh is running (lock: $FLEET_LOCK_FILE)"
    return 1
  fi
}

# Copy everything printed from here on to logs/<name>-<timestamp>.log.
fleet_start_log() {
  mkdir -p "$FLEET_DIR/logs"
  FLEET_LOG_FILE="$FLEET_DIR/logs/$1-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$FLEET_LOG_FILE") 2>&1
  fleet_info "=== Logging this run to $FLEET_LOG_FILE ==="
}

# --- SSH --------------------------------------------------------------------
# Both return ssh's status unchanged: 255 means ssh itself failed
# (unreachable, key rejected); anything else is the remote command's status.
# COMMAND is joined into one string for the remote shell, so quote it for
# that shell.
#
# fleet_ssh HOST COMMAND...         stdin is /dev/null (ssh -n). Without -n,
#   ssh reads the caller's stdin and swallows the rest of a "while read"
#   loop or of a script fed to bash on stdin.
# fleet_ssh_script HOST COMMAND...  passes stdin to the remote command,
#   e.g. fleet_ssh_script HOST bash -s -- ARGS <<< "$SCRIPT".
fleet_ssh() {
  local host=$1
  shift
  ssh -n "${FLEET_SSH_OPTS[@]}" -- "$FLEET_SSH_USER@$host" "$@"
}
fleet_ssh_script() {
  local host=$1
  shift
  ssh "${FLEET_SSH_OPTS[@]}" -- "$FLEET_SSH_USER@$host" "$@"
}

# --- Hooks (contract: hooks/README.md) ---------------------------------------
# fleet_run_hooks PHASE DRY_RUN FORCE -- runs hooks/<host>.<PHASE>.sh for each
# selected host that has one, under timeout. Fail-closed: any non-zero exit,
# a timeout, or a hook file that isn't executable is a failure. Failures are
# collected in FLEET_HOOK_FAILED ("host: reason"); the caller decides.
fleet_run_hooks() {
  local phase=$1 dry_run=$2 force=$3 host hook rc reason found=0
  FLEET_HOOK_FAILED=()
  for host in "${FLEET_HOSTS[@]}"; do
    hook="$FLEET_DIR/hooks/$host.$phase.sh"
    if [[ ! -e $hook ]]; then
      continue
    fi
    found=$(( found + 1 ))
    if [[ ! -x $hook ]]; then
      reason="hook file exists but is not executable"
    elif [[ $dry_run == true ]]; then
      fleet_info "[DRY RUN] would run $phase hook for $host"
      continue
    else
      fleet_info "--- $phase hook for $host (timeout ${FLEET_HOOK_TIMEOUT}s) ---"
      rc=0
      FLEET_HOST=$host FLEET_FORCE=$force \
        timeout -k 5 "$FLEET_HOOK_TIMEOUT" "$hook" || rc=$?
      case $rc in
        0)   fleet_info "--- $phase hook for $host: OK ---"; continue ;;
        1)   reason="hook reported a failure (exit 1)" ;;
        124) reason="timed out after ${FLEET_HOOK_TIMEOUT}s" ;;
        *)   reason="hook could not check (exit $rc)" ;;
      esac
    fi
    fleet_warn "$phase hook for $host: $reason"
    FLEET_HOOK_FAILED+=("$host: $reason")
  done
  if (( found == 0 )); then
    fleet_info "no $phase hooks for the selected hosts"
  elif [[ $dry_run != true ]]; then
    fleet_info "$phase hooks: $found found, ${#FLEET_HOOK_FAILED[@]} failed"
  fi
}

# --- Checks (contract: checks.d/README.md) -----------------------------------
# A check script reports each finding with one of the first three and ends
# with fleet_check_exit: 1 if anything failed, else 2 if anything could not
# be checked, else 0.
FLEET_CHECK_N_OK=0 FLEET_CHECK_N_FAIL=0 FLEET_CHECK_N_CANNOT=0
fleet_check_ok()     { printf '  [OK]     %s\n' "$*"; FLEET_CHECK_N_OK=$(( FLEET_CHECK_N_OK + 1 )); }
fleet_check_fail()   { printf '  [FAIL]   %s\n' "$*"; FLEET_CHECK_N_FAIL=$(( FLEET_CHECK_N_FAIL + 1 )); }
fleet_check_cannot() { printf '  [CANNOT] %s\n' "$*"; FLEET_CHECK_N_CANNOT=$(( FLEET_CHECK_N_CANNOT + 1 )); }
fleet_check_exit() {
  if (( FLEET_CHECK_N_FAIL > 0 )); then exit 1; fi
  if (( FLEET_CHECK_N_CANNOT > 0 )); then exit 2; fi
  if (( FLEET_CHECK_N_OK == 0 )); then
    printf '  [CANNOT] %s\n' "check reported nothing"; exit 2
  fi
  exit 0
}

# --- Arguments --------------------------------------------------------------
# Common options. Sets FLEET_ONLY, FLEET_SKIP, FLEET_DRY_RUN, FLEET_SHOW_HELP
# and leaves every other argument, in order, in FLEET_ARGS for the script.
# shellcheck disable=SC2034  # these variables are read by the calling script
fleet_parse_args() {
  local arg
  FLEET_ONLY=""
  FLEET_SKIP=""
  FLEET_DRY_RUN=false
  FLEET_SHOW_HELP=false
  FLEET_ARGS=()
  for arg in "$@"; do
    case $arg in
      -h|--help) FLEET_SHOW_HELP=true ;;
      --only=*)  FLEET_ONLY=${arg#--only=} ;;
      --skip=*)  FLEET_SKIP=${arg#--skip=} ;;
      --dry-run) FLEET_DRY_RUN=true ;;
      *)         FLEET_ARGS+=("$arg") ;;
    esac
  done
}

fleet_validate_config || return "$FLEET_EXIT_USAGE"
FLEET_SSH_OPTS=(
  -i "$FLEET_SSH_KEY"
  -o BatchMode=yes
  -o ConnectTimeout="$FLEET_SSH_CONNECT_TIMEOUT"
  -o StrictHostKeyChecking="$FLEET_SSH_HOST_KEY_CHECKING"
)
