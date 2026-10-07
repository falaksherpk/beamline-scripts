#!/usr/bin/env bash
# Kubernetes and Argo CD, from JSON (not table text: "NotReady" contains "Ready").
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"
HOST=k8cp.beamline
json=""

# kube_json VAR WHAT KUBECTL-ARGS -- JSON into VAR, or report and return 1.
# Returns through a nameref, not stdout: called as json=$(...), the report
# and its count would happen in a subshell and be lost.
kube_json() {
  local -n _json=$1
  local what=$2 out rc=0
  shift 2
  out=$(fleet_ssh "$HOST" "kubectl $* -o json" 2>&1) || rc=$?
  if (( rc == 255 )); then fleet_check_cannot "$what: ssh to $HOST failed: $out"; return 1; fi
  if (( rc != 0 )); then fleet_check_fail "$what: kubectl exited $rc: ${out:0:300}"; return 1; fi
  _json=$out
}

if kube_json json nodes get nodes; then
  line=$(python3 -c 'import json,sys
items = json.load(sys.stdin)["items"]
bad = []
for n in items:
    r = next((c["status"] for c in n["status"].get("conditions", []) if c["type"] == "Ready"), "unknown")
    if r != "True":
        bad.append(n["metadata"]["name"] + " Ready=" + r)
print(len(items), "|", "; ".join(bad))' <<< "$json")
  n=${line%% |*}; bad=${line#*| }
  if [[ $n -gt 0 && -z $bad ]]; then fleet_check_ok "nodes: all $n Ready"
  elif [[ $n -eq 0 ]]; then fleet_check_fail "nodes: none found"
  else fleet_check_fail "nodes: $bad"; fi
fi

if kube_json json pods get pods -A; then
  line=$(python3 -c 'import json,sys
items = json.load(sys.stdin)["items"]
bad = []
for p in items:
    st = p["status"]; cs = st.get("containerStatuses", [])
    ready = sum(1 for c in cs if c.get("ready")); phase = st.get("phase", "?")
    if phase == "Succeeded":
        continue
    if phase != "Running" or not cs or ready != len(cs):
        bad.append(p["metadata"]["namespace"] + "/" + p["metadata"]["name"] + " " + phase + " " + str(ready) + "/" + str(len(cs)))
print(len(items), "|", "; ".join(bad))' <<< "$json")
  n=${line%% |*}; bad=${line#*| }
  if [[ -z $bad ]]; then fleet_check_ok "pods: all $n Running with every container ready (or Succeeded)"
  else fleet_check_fail "pods not ready: $bad"; fi
fi

if kube_json json "Argo CD applications" -n argocd get applications.argoproj.io; then
  line=$(python3 -c 'import json,sys
items = json.load(sys.stdin)["items"]
bad = []
for a in items:
    s = a.get("status", {})
    sync = s.get("sync", {}).get("status", "?"); health = s.get("health", {}).get("status", "?")
    if (sync, health) != ("Synced", "Healthy"):
        bad.append(a["metadata"]["name"] + " " + sync + "/" + health)
print(len(items), "|", "; ".join(bad))' <<< "$json")
  n=${line%% |*}; bad=${line#*| }
  if [[ $n -gt 0 && -z $bad ]]; then fleet_check_ok "Argo CD: all $n applications Synced/Healthy"
  elif [[ $n -eq 0 ]]; then fleet_check_fail "Argo CD: no applications found"
  else fleet_check_fail "Argo CD: $bad"; fi
fi

fleet_check_exit
