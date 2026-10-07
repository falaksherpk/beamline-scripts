#!/usr/bin/env bash
# fleet-down.sh -- graceful, tiered shutdown of the beamline VM fleet.
set -euo pipefail
# shellcheck source=./fleet-lib.sh
source "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/fleet-lib.sh"

usage() {
  cat << USAGE
Usage: fleet-down.sh [--only=<list> | --skip=<list>] [--force] [--force-stop] [--dry-run]

Shut down the beamline VM fleet (or a subset) tier by tier, last tier first:
run pre-shutdown hooks, request an ACPI shutdown for each VM of a tier
(${FLEET_SHUTDOWN_STAGGER}s apart), wait up to ${FLEET_SHUTDOWN_TIMEOUT}s for the whole tier to reach
"shut off", then move on to the next tier.

Options:
  --only=<group,host,...>  Only these groups/hosts (comma-separated; names in fleet.conf)
  --skip=<group,host,...>  Everything except these
  --force                  Continue even if a pre-shutdown hook fails
  --force-stop             Hard power-off (virsh destroy) VMs still running after
                           the timeout. Without it, the run stops at that tier and
                           leaves the remaining tiers running.
  --dry-run                Show the plan; run no hooks, touch no VM
  -h, --help               Show this help

Exit codes: 0 every selected VM shut off cleanly, with no hook failure;
            1 anything else (hook failure, timeout, forced stop, virsh error);
            2 usage or configuration error.
USAGE
}

fleet_parse_args "$@"
FORCE=false
FORCE_STOP=false
for arg in "${FLEET_ARGS[@]}"; do
  case $arg in
    --force)      FORCE=true ;;
    --force-stop) FORCE_STOP=true ;;
    *) fleet_error "unknown argument: $arg (see --help)"; exit "$FLEET_EXIT_USAGE" ;;
  esac
done
if [[ $FLEET_SHOW_HELP == true ]]; then usage; exit "$FLEET_EXIT_OK"; fi
fleet_select_hosts "$FLEET_ONLY" "$FLEET_SKIP" || exit "$FLEET_EXIT_USAGE"
fleet_check_domains || exit "$FLEET_EXIT_USAGE"
fleet_lock || exit "$FLEET_EXIT_FAIL"
fleet_start_log fleet-down

FAILURES=()
CLEAN=()
ALREADY_OFF=()
FORCED=()

fleet_section "Target hosts, shutdown order (last tier first)"
for (( t = ${#FLEET_TIERS[@]} - 1; t >= 0; t-- )); do
  mapfile -t tier_hosts < <(fleet_tier_selected "$t")
  if (( ${#tier_hosts[@]} > 0 )); then fleet_info "tier $((t + 1)): ${tier_hosts[*]}"; fi
done

fleet_section "Pre-shutdown hooks"
fleet_run_hooks pre-shutdown "$FLEET_DRY_RUN" "$FORCE"
if (( ${#FLEET_HOOK_FAILED[@]} > 0 )); then
  if [[ $FORCE != true ]]; then
    fleet_error "pre-shutdown hook failure -- aborting before any VM is touched (--force overrides):"
    printf '  %s\n' "${FLEET_HOOK_FAILED[@]}" >&2
    exit "$FLEET_EXIT_FAIL"
  fi
  fleet_warn "--force given: continuing despite ${#FLEET_HOOK_FAILED[@]} hook failure(s)"
  for f in "${FLEET_HOOK_FAILED[@]}"; do FAILURES+=("hook $f (overridden by --force)"); done
fi

if [[ $FLEET_DRY_RUN == true ]]; then
  fleet_section "DRY RUN: no VM touched"
  exit "$FLEET_EXIT_OK"
fi

STOPPED_AT=""
for (( t = ${#FLEET_TIERS[@]} - 1; t >= 0; t-- )); do
  mapfile -t tier_hosts < <(fleet_tier_selected "$t")
  if (( ${#tier_hosts[@]} == 0 )); then continue; fi
  fleet_section "Tier $((t + 1)): ACPI shutdown, ${FLEET_SHUTDOWN_STAGGER}s apart"
  waiting=()
  for h in "${tier_hosts[@]}"; do
    if ! state=$(fleet_domstate "$h"); then
      fleet_error "$h: virsh domstate failed"; FAILURES+=("$h: virsh domstate failed"); continue
    fi
    if [[ $state == "shut off" ]]; then
      fleet_info "$h: already shut off"; ALREADY_OFF+=("$h"); continue
    fi
    if (( ${#waiting[@]} > 0 )); then sleep "$FLEET_SHUTDOWN_STAGGER"; fi
    if out=$(virsh shutdown --mode acpi "$h" 2>&1); then
      fleet_info "$h: shutdown requested (was $state)"; waiting+=("$h")
    else
      fleet_error "$h: virsh shutdown failed: $out"; FAILURES+=("$h: virsh shutdown failed")
    fi
  done
  if (( ${#waiting[@]} == 0 )); then continue; fi

  fleet_info "waiting up to ${FLEET_SHUTDOWN_TIMEOUT}s for: ${waiting[*]}"
  start=$SECONDS
  deadline=$(( SECONDS + FLEET_SHUTDOWN_TIMEOUT ))
  while :; do
    remaining=()
    for h in "${waiting[@]}"; do
      state=$(fleet_domstate "$h") || state="unknown"
      if [[ $state == "shut off" ]]; then continue; fi
      remaining+=("$h")
    done
    if (( ${#remaining[@]} == 0 || SECONDS >= deadline )); then break; fi
    sleep "$FLEET_POLL_INTERVAL"
  done
  for h in "${waiting[@]}"; do
    if [[ ! " ${remaining[*]} " == *" $h "* ]]; then CLEAN+=("$h"); fi
  done
  if (( ${#remaining[@]} == 0 )); then
    fleet_info "tier $((t + 1)): all shut off after $(( SECONDS - start ))s"
    continue
  fi

  fleet_warn "tier $((t + 1)): still running after ${FLEET_SHUTDOWN_TIMEOUT}s: ${remaining[*]}"
  if [[ $FORCE_STOP == true ]]; then
    for h in "${remaining[@]}"; do
      if out=$(virsh destroy "$h" 2>&1); then
        fleet_warn "$h: forced off (virsh destroy)"; FORCED+=("$h")
      else
        fleet_error "$h: virsh destroy failed: $out"
      fi
      FAILURES+=("$h: did not shut down within ${FLEET_SHUTDOWN_TIMEOUT}s")
    done
  else
    for h in "${remaining[@]}"; do FAILURES+=("$h: did not shut down within ${FLEET_SHUTDOWN_TIMEOUT}s"); done
    STOPPED_AT=$(( t + 1 ))
    if (( STOPPED_AT > 1 )); then
      fleet_error "stopping at tier $STOPPED_AT: tiers 1 to $(( STOPPED_AT - 1 )) are left running (--force-stop powers off instead)"
    else
      fleet_error "stopping at tier 1 (--force-stop powers off instead)"
    fi
    break
  fi
done

fleet_section "Libvirt state"
virsh list --all

fleet_section "Summary ($(fleet_elapsed))"
fleet_info "shut off cleanly (${#CLEAN[@]}): ${CLEAN[*]:-none}"
if (( ${#ALREADY_OFF[@]} > 0 )); then fleet_info "already off (${#ALREADY_OFF[@]}): ${ALREADY_OFF[*]}"; fi
if (( ${#FORCED[@]} > 0 )); then fleet_info "forced off (${#FORCED[@]}): ${FORCED[*]}"; fi
if [[ -n $STOPPED_AT ]] && (( STOPPED_AT > 1 )); then
  fleet_info "not attempted: every selected host in tiers 1 to $(( STOPPED_AT - 1 ))"
fi
if (( ${#FAILURES[@]} > 0 )); then
  fleet_info "FAILED (${#FAILURES[@]}):"
  printf '  %s\n' "${FAILURES[@]}"
  exit "$FLEET_EXIT_FAIL"
fi
fleet_info "result: OK"
exit "$FLEET_EXIT_OK"
