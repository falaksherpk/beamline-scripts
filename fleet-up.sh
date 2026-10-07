#!/usr/bin/env bash
# fleet-up.sh -- tiered start of the beamline VM fleet, with SSH and network checks.
set -euo pipefail
# shellcheck source=./fleet-lib.sh
source "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/fleet-lib.sh"

usage() {
  cat << USAGE
Usage: fleet-up.sh [--only=<list> | --skip=<list>] [--with-healthcheck] [--dry-run]

Start the beamline VM fleet (or a subset) tier by tier, first tier first:
start each shut-off VM of a tier (${FLEET_START_STAGGER}s apart), wait up to ${FLEET_SSH_WAIT_TIMEOUT}s per host
for SSH, then move on to the next tier (a host that doesn't come up is
reported, and the next tier still starts). Then check every ready host
(hostname; IPv4 on: ${FLEET_IFACES}; ping ${FLEET_INTERNET_PROBE}) and run post-boot hooks.

Options:
  --only=<group,host,...>  Only these groups/hosts (comma-separated; names in fleet.conf)
  --skip=<group,host,...>  Everything except these
  --with-healthcheck       Run fleet-check.sh at the end
  --dry-run                Show the plan; start no VM, run no check or hook
  -h, --help               Show this help

Exit codes: 0 every selected host up and every check and hook passed;
            1 anything else; 2 usage or configuration error.
USAGE
}

# Runs on each VM via "bash -s -- PROBE IFACE...": one line per fact.
# shellcheck disable=SC2016  # expanded by the remote shell, not here
REMOTE_CHECK='probe=$1; shift
echo "hostname $(hostname)"
for i in "$@"; do
  echo "iface $i $(ip -4 -o addr show dev "$i" 2>/dev/null | awk "{print \$4; exit}")"
done
if ping -c1 -W2 "$probe" >/dev/null 2>&1; then echo "internet OK"; else echo "internet FAIL"; fi'

fleet_parse_args "$@"
WITH_HEALTHCHECK=false
for arg in "${FLEET_ARGS[@]}"; do
  case $arg in
    --with-healthcheck) WITH_HEALTHCHECK=true ;;
    *) fleet_error "unknown argument: $arg (see --help)"; exit "$FLEET_EXIT_USAGE" ;;
  esac
done
if [[ $FLEET_SHOW_HELP == true ]]; then usage; exit "$FLEET_EXIT_OK"; fi
fleet_select_hosts "$FLEET_ONLY" "$FLEET_SKIP" || exit "$FLEET_EXIT_USAGE"
fleet_check_domains || exit "$FLEET_EXIT_USAGE"
read -ra IFACES <<< "$FLEET_IFACES"
fleet_lock || exit "$FLEET_EXIT_FAIL"
fleet_start_log fleet-up

FAILURES=()
STARTED=()
ALREADY_RUNNING=()
READY=()
declare -A STARTED_AT=()

# Background job: poll SSH until it answers or the deadline passes.
# STARTED is the SECONDS value at this host's "virsh start" (empty if it
# was already running), so the time reported is the host's own boot time,
# not the time since the tier's last VM was started.
# On timeout, print ssh's last error: "no SSH" alone would hide a host-key
# mismatch (StrictHostKeyChecking=yes) behind what looks like a slow boot.
wait_for_ssh() {
  local h=$1 started=$2 err=""
  local deadline=$(( SECONDS + FLEET_SSH_WAIT_TIMEOUT ))
  while (( SECONDS < deadline )); do
    if err=$(fleet_ssh "$h" true 2>&1); then
      if [[ -n $started ]]; then
        fleet_info "$h: SSH ready $(( SECONDS - started ))s after start"
      else
        fleet_info "$h: SSH ready (was already running)"
      fi
      return 0
    fi
    sleep "$FLEET_POLL_INTERVAL"
  done
  fleet_warn "$h: no SSH after ${FLEET_SSH_WAIT_TIMEOUT}s; last ssh error: ${err:-none}"
  return 1
}

# One line per host; every failed fact is a failure of the run.
check_host() {
  local h=$1 out rc=0 problems=() line i addr
  local -A facts=()
  out=$(fleet_ssh_script "$h" bash -s -- "$FLEET_INTERNET_PROBE" "${IFACES[@]}" <<< "$REMOTE_CHECK" 2>&1) || rc=$?
  if (( rc == 255 )); then
    FAILURES+=("$h: check: ssh failed: $out"); fleet_error "$h: ssh failed: $out"; return
  elif (( rc != 0 )); then
    FAILURES+=("$h: check script exited $rc"); fleet_error "$h: check script exited $rc: $out"; return
  fi
  while read -r line; do
    case $line in
      "hostname "*) facts[hostname]=${line#hostname } ;;
      "iface "*)    line=${line#iface }; facts[iface:${line%% *}]=${line#* } ;;
      "internet "*) facts[internet]=${line#internet } ;;
    esac
  done <<< "$out"
  local summary="hostname ${facts[hostname]:-?}"
  if [[ ${facts[hostname]:-} != "$h" ]]; then problems+=("hostname is '${facts[hostname]:-}'"); fi
  for i in "${IFACES[@]}"; do
    addr=${facts[iface:$i]:-}
    if [[ -z $addr || $addr == "$i" ]]; then problems+=("no IPv4 on $i"); addr="none"; fi
    summary+=", $i $addr"
  done
  summary+=", internet ${facts[internet]:-?}"
  if [[ ${facts[internet]:-} != OK ]]; then problems+=("ping $FLEET_INTERNET_PROBE failed"); fi
  if (( ${#problems[@]} == 0 )); then
    fleet_info "$h: OK -- $summary"
  else
    fleet_error "$h: $summary -- $(IFS=';'; echo "${problems[*]}")"
    for i in "${problems[@]}"; do FAILURES+=("$h: $i"); done
  fi
}

fleet_section "Target hosts, start order (first tier first)"
for t in "${!FLEET_TIERS[@]}"; do
  mapfile -t tier_hosts < <(fleet_tier_selected "$t")
  if (( ${#tier_hosts[@]} > 0 )); then fleet_info "tier $((t + 1)): ${tier_hosts[*]}"; fi
done

for t in "${!FLEET_TIERS[@]}"; do
  mapfile -t tier_hosts < <(fleet_tier_selected "$t")
  if (( ${#tier_hosts[@]} == 0 )); then continue; fi
  fleet_section "Tier $((t + 1)): start, ${FLEET_START_STAGGER}s apart"
  to_wait=()
  started_here=0
  # Each host's SSH wait starts right after its own "virsh start", so it
  # probes during the stagger and reports that host's real boot time.
  declare -A pids=()
  for h in "${tier_hosts[@]}"; do
    if ! state=$(fleet_domstate "$h"); then
      fleet_error "$h: virsh domstate failed"; FAILURES+=("$h: virsh domstate failed"); continue
    fi
    case $state in
      "shut off")
        if [[ $FLEET_DRY_RUN == true ]]; then fleet_info "[DRY RUN] would start $h"; continue; fi
        if (( started_here > 0 )); then sleep "$FLEET_START_STAGGER"; fi
        if out=$(virsh start "$h" 2>&1); then
          STARTED_AT[$h]=$SECONDS
          fleet_info "$h: started"; STARTED+=("$h"); to_wait+=("$h"); started_here=$(( started_here + 1 ))
          wait_for_ssh "$h" "${STARTED_AT[$h]}" &
          pids[$h]=$!
        else
          fleet_error "$h: virsh start failed: $out"; FAILURES+=("$h: virsh start failed")
        fi ;;
      running)
        fleet_info "$h: already running"; ALREADY_RUNNING+=("$h"); to_wait+=("$h")
        wait_for_ssh "$h" "" &
        pids[$h]=$! ;;
      *)
        fleet_error "$h: state '$state' -- not starting it; resolve by hand"
        FAILURES+=("$h: unexpected state '$state'") ;;
    esac
  done
  if [[ $FLEET_DRY_RUN == true || ${#to_wait[@]} -eq 0 ]]; then unset pids; continue; fi

  fleet_info "waiting up to ${FLEET_SSH_WAIT_TIMEOUT}s per host for SSH: ${to_wait[*]}"
  # Wait on these PIDs only: a bare "wait" would also wait for the tee
  # process that copies output to the log, which never exits on its own.
  for h in "${to_wait[@]}"; do
    if wait "${pids[$h]}"; then
      READY+=("$h")
    else
      FAILURES+=("$h: no SSH within ${FLEET_SSH_WAIT_TIMEOUT}s")
    fi
  done
  unset pids
done

if [[ $FLEET_DRY_RUN == true ]]; then
  fleet_section "Post-boot hooks"
  fleet_run_hooks post-boot true false
  fleet_section "DRY RUN: no VM started"
  exit "$FLEET_EXIT_OK"
fi

fleet_section "Libvirt state"
virsh list --all

if (( ${#READY[@]} > 0 )); then
  fleet_section "Per-host checks"
  for h in "${READY[@]}"; do check_host "$h"; done

  fleet_section "Post-boot hooks (ready hosts only)"
  SELECTED=("${FLEET_HOSTS[@]}")
  FLEET_HOSTS=("${READY[@]}")
  fleet_run_hooks post-boot false false
  FLEET_HOSTS=("${SELECTED[@]}")
  for f in "${FLEET_HOOK_FAILED[@]}"; do FAILURES+=("hook $f"); done
fi

if [[ $WITH_HEALTHCHECK == true ]]; then
  fleet_section "fleet-check.sh (--with-healthcheck)"
  if ! "$FLEET_DIR/fleet-check.sh"; then FAILURES+=("fleet-check.sh reported failures"); fi
fi

fleet_section "Summary ($(fleet_elapsed))"
fleet_info "ready (${#READY[@]}/${#FLEET_HOSTS[@]}): ${READY[*]:-none}"
fleet_info "started by this run (${#STARTED[@]}): ${STARTED[*]:-none}"
if (( ${#ALREADY_RUNNING[@]} > 0 )); then fleet_info "already running (${#ALREADY_RUNNING[@]}): ${ALREADY_RUNNING[*]}"; fi
if (( ${#FAILURES[@]} > 0 )); then
  fleet_info "FAILED (${#FAILURES[@]}):"
  printf '  %s\n' "${FAILURES[@]}"
  exit "$FLEET_EXIT_FAIL"
fi
fleet_info "result: OK"
exit "$FLEET_EXIT_OK"
