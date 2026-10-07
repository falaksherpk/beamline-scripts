#!/usr/bin/env bash
# GitLab: web UI (from here), readiness (on the VM: /-/readiness answers
# localhost only), container registry (from here), runner service.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"
HOST=gitlab.beamline
WEB="https://$HOST/users/sign_in"
REGISTRY="https://$HOST:5050/v2/"

# curl -s plus -w fields keep curl's own errors apart from the HTTP status
# (curl >= 7.75 for %{exitcode} and %{errormsg}).
IFS='|' read -r code cexit cerr < <(curl -s -o /dev/null --connect-timeout 5 \
  -w '%{http_code}|%{exitcode}|%{errormsg}\n' "$WEB")
if [[ ${cexit:-x} != 0 ]]; then fleet_check_fail "web UI: $WEB -> no answer (curl exit ${cexit:-?}: ${cerr:-})"
elif [[ $code == 200 ]]; then fleet_check_ok "web UI: $WEB -> 200"
else fleet_check_fail "web UI: $WEB -> HTTP $code (want 200)"; fi

rc=0
ready=$(fleet_ssh "$HOST" "curl -sS --resolve $HOST:443:127.0.0.1 'https://$HOST/-/readiness?all=1'" 2>&1) || rc=$?
if (( rc == 255 )); then
  fleet_check_cannot "readiness: ssh to $HOST failed: $ready"
elif (( rc != 0 )); then
  fleet_check_fail "readiness: curl on $HOST exited $rc: $ready"
else
  verdict=$(python3 -c 'import json,sys
d = json.load(sys.stdin)
bad = [k for k, v in d.items() if isinstance(v, list) and any(c.get("status") != "ok" for c in v)]
print(d.get("status", "?") + ("" if not bad else " (not ok: " + ", ".join(bad) + ")"))' <<< "$ready" 2>&1) || verdict="unparseable: ${ready:0:200}"
  if [[ $verdict == ok ]]; then fleet_check_ok "readiness (on $HOST): status ok, every subcheck ok"
  else fleet_check_fail "readiness (on $HOST): $verdict"; fi
fi

out=$(curl -s -o /dev/null -D - --connect-timeout 5 \
  -w '__curl|%{exitcode}|%{errormsg}\n' "$REGISTRY" | tr -d '\r')
IFS='|' read -r _ cexit cerr <<< "$(grep '^__curl|' <<< "$out")"
headers=$(grep -v '^__curl|' <<< "$out")
status=$(head -n1 <<< "$headers" | awk '{print $2}')
if [[ ${cexit:-x} != 0 ]]; then
  fleet_check_fail "registry: $REGISTRY -> no answer (curl exit ${cexit:-?}: ${cerr:-})"
elif [[ $status == 401 ]] && grep -qi '^docker-distribution-api-version: registry/2.0$' <<< "$headers"; then
  fleet_check_ok "registry: $REGISTRY -> 401 + registry/2.0 header (answers, wants auth)"
else
  fleet_check_fail "registry: $REGISTRY -> HTTP ${status:-?}; want 401 with Docker-Distribution-Api-Version: registry/2.0"
fi

rc=0
state=$(fleet_ssh "$HOST" 'systemctl is-active gitlab-runner' 2>&1) || rc=$?
if (( rc == 255 )); then fleet_check_cannot "runner: ssh to $HOST failed: $state"
elif [[ $state == active ]]; then fleet_check_ok "runner: gitlab-runner service active on $HOST"
else fleet_check_fail "runner: gitlab-runner service on $HOST is '$state'"; fi

fleet_check_exit
