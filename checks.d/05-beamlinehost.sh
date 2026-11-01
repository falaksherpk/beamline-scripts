#!/usr/bin/env bash
# beamlinehost itself (handbook Part 3, Ch32's open item): the hypervisor every VM boots
# its clock from, and the operator's console. chrony enabled and active; chrony tracking
# a real source, leap status Normal, the system clock within MAX_OFFSET seconds of it;
# the kernel's clock synchronized and the timezone the common role sets; GNOME Remote
# Login (the system gnome-remote-desktop daemon) off, as the operator_gui role leaves
# it. Runs on beamlinehost only, without ssh. Read-only: nothing is changed.
#
# Why: in Oct 2026 chrony was found disabled here, the clock 30 s fast, for at least 16
# days. The VMs came up ~28 s fast after each cold boot and Taurus trends showed live
# data as stale; no check looked at this host.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"

# Overridable only to test the check against a wrong target (checks.d/README.md).
HOST=${CHECK_BH_HOST:-beamlinehost}
CHRONY_UNIT=${CHECK_BH_CHRONY_UNIT:-chrony.service}
MAX_OFFSET=${CHECK_BH_MAX_OFFSET:-1.0}
TIMEZONE=${CHECK_BH_TIMEZONE:-Etc/UTC}
REMOTE_LOGIN_UNIT=${CHECK_BH_REMOTE_LOGIN_UNIT:-gnome-remote-desktop.service}
TOOL_TIMEOUT=10

one() { tr '\n' ' ' <<< "$1" | tr -s ' ' | sed 's/ $//' | cut -c1-200; }

this_host=$(hostname)
if [[ $this_host != "$HOST" ]]; then
  printf '  (skipped: runs on %s only; this is %s)\n' "$HOST" "$this_host"
  exit 3
fi

# 1. The chrony unit.
a=$(systemctl is-active "$CHRONY_UNIT" 2>&1)
e=$(systemctl is-enabled "$CHRONY_UNIT" 2>&1)
if [[ $a == active && $e == enabled ]]; then
  fleet_check_ok "$CHRONY_UNIT: active, enabled"
else
  fleet_check_fail "$CHRONY_UNIT: $(one "$a"), $(one "$e") (want active, enabled)"
fi

# 2. chrony's tracking, from its CSV output (chrony 4.5: 14 fields; 1 reference ID,
#    2 source, 5 system-time offset in seconds, 14 leap status). The offset's sign is
#    chrony's correction, so only its size is compared.
if ! t=$(timeout "$TOOL_TIMEOUT" chronyc -n -c tracking 2>&1); then
  fleet_check_cannot "chronyc tracking: $(one "$t")"
else
  IFS=, read -r -a f <<< "$t"
  if (( ${#f[@]} != 14 )) || [[ ! ${f[4]} =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    fleet_check_cannot "chronyc tracking: unparseable ($(one "$t"))"
  else
    ref_id=${f[0]} src=${f[1]} offset=${f[4]} leap=${f[13]}
    size=$(awk -v o="$offset" 'BEGIN { printf "%.6f", (o < 0 ? -o : o) }')
    if [[ $ref_id == 00000000 || $ref_id == 7F7F0101 ]]; then
      fleet_check_fail "chrony: no time source (reference $ref_id, leap $leap)"
    elif [[ $leap != Normal ]]; then
      fleet_check_fail "chrony: leap status '$leap' (want Normal), source $src"
    elif awk -v s="$size" -v m="$MAX_OFFSET" 'BEGIN { exit !(s <= m) }'; then
      fleet_check_ok "chrony: source $src, leap Normal, offset ${size} s (limit $MAX_OFFSET s)"
    else
      fleet_check_fail "chrony: offset ${size} s from $src (limit $MAX_OFFSET s)"
    fi
  fi
fi

# 3. The kernel's view, and the timezone (key=value: --value would print in
#    timedatectl's own order, not the order asked for).
if ! td=$(timeout "$TOOL_TIMEOUT" timedatectl show -p NTPSynchronized -p Timezone 2>&1); then
  fleet_check_cannot "timedatectl: $(one "$td")"
else
  sync=$(sed -n 's/^NTPSynchronized=//p' <<< "$td")
  tz=$(sed -n 's/^Timezone=//p' <<< "$td")
  if [[ -z $sync || -z $tz ]]; then
    fleet_check_cannot "timedatectl: unparseable ($(one "$td"))"
  else
    if [[ $sync == yes ]]; then
      fleet_check_ok "timedatectl: NTPSynchronized=yes"
    else
      fleet_check_fail "timedatectl: NTPSynchronized=$sync (want yes)"
    fi
    if [[ $tz == "$TIMEZONE" ]]; then
      fleet_check_ok "timedatectl: Timezone=$tz"
    else
      fleet_check_fail "timedatectl: Timezone=$tz (want $TIMEZONE)"
    fi
  fi
fi

# 4. GNOME Remote Login off: switched on, it logs the RDP user into a new headless
#    session, which ends the operator's seat0 session and renders with llvmpipe (Ch32).
a=$(systemctl is-active "$REMOTE_LOGIN_UNIT" 2>&1)
e=$(systemctl is-enabled "$REMOTE_LOGIN_UNIT" 2>&1)
if [[ ($e == disabled || $e == masked) && $a != active ]]; then
  fleet_check_ok "$REMOTE_LOGIN_UNIT (Remote Login): $e, $a"
else
  fleet_check_fail "$REMOTE_LOGIN_UNIT (Remote Login): $(one "$e"), $(one "$a") (want disabled, not active)"
fi

fleet_check_exit
