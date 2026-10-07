#!/usr/bin/env bash
# Rootless Podman on pkg.beamline (Ch12: runs as the login user).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"
HOST=pkg.beamline

rc=0
out=$(fleet_ssh "$HOST" "podman info --format '{{.Host.Security.Rootless}}'" 2>&1) || rc=$?
if (( rc == 255 )); then fleet_check_cannot "podman: ssh to $HOST failed: $out"
elif (( rc != 0 )); then fleet_check_fail "podman: 'podman info' on $HOST exited $rc: ${out:0:300}"
elif [[ $out == true ]]; then fleet_check_ok "podman: responsive and rootless on $HOST"
else fleet_check_fail "podman: on $HOST answers, but rootless=$out (want true)"; fi

fleet_check_exit
