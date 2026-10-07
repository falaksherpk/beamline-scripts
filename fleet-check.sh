#!/usr/bin/env bash
# fleet-check.sh -- run the health checks in checks.d/ and summarise them.
set -euo pipefail
# shellcheck source=./fleet-lib.sh
source "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/fleet-lib.sh"

CHECKS_DIR=${FLEET_CHECKS_DIR:-$FLEET_DIR/checks.d}

usage() {
  cat << USAGE
Usage: fleet-check.sh [--slow]

Run every executable checks.d/*.sh in name order, each under timeout
(${FLEET_CHECK_TIMEOUT}s; ${FLEET_SLOW_CHECK_TIMEOUT}s for *.slow.sh), and summarise. Read-only: changes nothing.

Options:
  --slow       Also run the slow checks (*.slow.sh, e.g. Ansible drift)
  -h, --help   Show this help

A check exits 0 OK, 1 FAIL, 2 could not check, 3 skipped (contract:
checks.d/README.md). A non-executable check is disabled and listed as such.

Exit codes: 0 no check failed or was unable to check; 1 otherwise;
            2 usage or configuration error.
USAGE
}

SLOW=false
for arg in "$@"; do
  case $arg in
    --slow)    SLOW=true ;;
    -h|--help) usage; exit "$FLEET_EXIT_OK" ;;
    *) fleet_error "unknown argument: $arg (see --help)"; exit "$FLEET_EXIT_USAGE" ;;
  esac
done
if [[ ! -d $CHECKS_DIR ]]; then
  fleet_error "no checks directory: $CHECKS_DIR"; exit "$FLEET_EXIT_USAGE"
fi

declare -A RESULT=()
NAMES=()
shopt -s nullglob
for check in "$CHECKS_DIR"/*.sh; do
  name=$(basename "$check" .sh)
  NAMES+=("$name")
  if [[ ! -x $check ]]; then
    RESULT[$name]="disabled (not executable)"; continue
  fi
  limit=$FLEET_CHECK_TIMEOUT
  if [[ $name == *.slow ]]; then
    if [[ $SLOW != true ]]; then RESULT[$name]="skipped (slow; use --slow)"; continue; fi
    limit=$FLEET_SLOW_CHECK_TIMEOUT
  fi
  fleet_section "$name (timeout ${limit}s)"
  start=$SECONDS
  rc=0
  timeout -k 5 "$limit" "$check" || rc=$?
  took=$(( SECONDS - start ))
  case $rc in
    0)   RESULT[$name]="OK (${took}s)" ;;
    1)   RESULT[$name]="FAIL (${took}s)" ;;
    2)   RESULT[$name]="COULD NOT CHECK (${took}s)" ;;
    3)   RESULT[$name]="skipped by the check (${took}s)" ;;
    124) RESULT[$name]="COULD NOT CHECK: timed out after ${limit}s"
         printf '  [CANNOT] timed out after %ss\n' "$limit" ;;
    *)   RESULT[$name]="COULD NOT CHECK: exit $rc (${took}s)" ;;
  esac
done

if (( ${#NAMES[@]} == 0 )); then
  fleet_error "no checks in $CHECKS_DIR"; exit "$FLEET_EXIT_FAIL"
fi

fleet_section "Summary ($(fleet_elapsed))"
bad=0
for name in "${NAMES[@]}"; do
  printf '  %-28s %s\n' "$name" "${RESULT[$name]}"
  case ${RESULT[$name]} in FAIL*|COULD\ NOT*) bad=$(( bad + 1 )) ;; esac
done
if (( bad > 0 )); then
  fleet_info "result: $bad check(s) failed or could not check"
  exit "$FLEET_EXIT_FAIL"
fi
fleet_info "result: OK"
exit "$FLEET_EXIT_OK"
