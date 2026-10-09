#!/usr/bin/env bash
# Observability on obs.beamline (handbook Ch16): Prometheus (ready, config
# reload, rules, targets), the alert path (Watchdog in Alertmanager, nothing
# else firing), beamline-healthcheck fresh and passing on every fleet host,
# Grafana over verified TLS, Prometheus/Alertmanager unreachable from here, and
# GitLab's metrics endpoints (scraped by obs) not served to this host.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"

# Overridable only to test the check against a wrong target (checks.d/README.md).
HOST=${CHECK_OBS_HOST:-obs.beamline}
GRAFANA="https://$HOST:3000/api/health"
# Seconds; the health check's timer runs every minute (alert BeamlineHealthcheckStale).
STALE=300
# GitLab's metrics (role gitlab, Ch16) are for obs only: Rails /-/metrics through
# GitLab's monitoring_whitelist, Workhorse/Gitaly through ufw; nginx's status
# server listens on every address and ufw must drop it too. Overridable only to
# test the check against a wrong target.
GITLAB=${CHECK_GITLAB_HOST:-gitlab.beamline}

read -ra hosts <<< "$(fleet_all_hosts | tr '\n' ' ')"

# 1. On obs: Prometheus and Alertmanager listen on its loopback only. The program
#    travels base64-encoded, so its quoting does not depend on two shells.
remote=$(base64 -w0 << 'PY'
import json, sys, urllib.error, urllib.parse, urllib.request

stale = float(sys.argv[1])
fleet = sys.argv[2:]
P = "http://127.0.0.1:9090"
AM = "http://127.0.0.1:9093"

# Jobs and target counts that role prometheus configures (beamline-ansible,
# templates/prometheus.yml.j2); keep the two in step. Job node: one per fleet host.
EXPECTED_JOBS = {
    "prometheus": 1, "alertmanager": 1,
    "gitlab-rails": 1, "gitlab-workhorse": 1, "gitlab-gitaly": 1,
    "kube-state-metrics": 1, "kubelet": 3, "cadvisor": 3,
}


def say(kind, msg):
    print(f"{kind}|{msg}", flush=True)


def fetch(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return r.status, r.read()


def prom(path):
    _, body = fetch(f"{P}/api/v1/{path}")
    d = json.loads(body)
    if d.get("status") != "success":
        raise RuntimeError(f"{path}: status {d.get('status')!r}")
    return d["data"]


def query(expr):
    return prom("query?query=" + urllib.parse.quote(expr))["result"]


def host_of(instance):
    return instance.rsplit(":", 1)[0]


def readiness():
    # No answer from the service under test is a failure, not "cannot".
    for name, base in (("prometheus", P), ("alertmanager", AM)):
        try:
            status = fetch(base + "/-/ready")[0]
        except urllib.error.HTTPError as exc:
            status = exc.code
        except OSError as exc:
            say("FAIL", f"{name}: {base}/-/ready -> no answer ({exc})")
            continue
        if status == 200:
            say("OK", f"{name}: ready")
        else:
            say("FAIL", f"{name}: {base}/-/ready -> HTTP {status} (want 200)")


def config_and_rules():
    r = query("prometheus_config_last_reload_successful")
    if r and r[0]["value"][1] == "1":
        say("OK", "prometheus: last configuration reload succeeded")
    else:
        say("FAIL", "prometheus: last configuration reload failed (running on an older config)")
    groups = prom("rules")["groups"]
    rules = [(g["name"], x) for g in groups for x in g["rules"]]
    bad = [f"{g}/{x['name']} ({x.get('lastError', '')})" for g, x in rules if x.get("health") != "ok"]
    if not rules:
        say("FAIL", "rules: none loaded")
    elif bad:
        say("FAIL", f"rules: not healthy: {'; '.join(bad)}")
    else:
        say("OK", f"rules: {len(groups)} groups, {len(rules)} rules, all healthy")


def targets():
    jobs = {}
    for t in prom("targets?state=active")["activeTargets"]:
        jobs.setdefault(t["labels"].get("job", "?"), []).append(t)
    if not jobs:
        say("FAIL", "targets: none active")
        return
    for job in sorted(jobs):
        ts = jobs[job]
        down = [f"{t['labels'].get('instance', '?')} ({t['health']}: {t.get('lastError', '')})"
                for t in ts if t["health"] != "up"]
        if down:
            say("FAIL", f"targets: job {job}: {len(ts) - len(down)}/{len(ts)} up; not up: {'; '.join(down)}")
        else:
            say("OK", f"targets: job {job}: {len(ts)}/{len(ts)} up")
    scraped = {host_of(t["labels"].get("instance", "")) for t in jobs.get("node", [])}
    missing = [h for h in fleet if h not in scraped]
    if missing:
        say("FAIL", f"targets: fleet hosts missing from job node: {', '.join(missing)}")
    else:
        say("OK", f"targets: all {len(fleet)} fleet hosts in job node")
    # A job that vanishes from prometheus.yml, or loses a target, would leave every
    # line above green: compare with what role prometheus configures.
    want = dict(EXPECTED_JOBS, node=len(fleet))
    wrong = [f"{j} {len(jobs.get(j, []))} (want {n})" for j, n in sorted(want.items())
             if len(jobs.get(j, [])) != n]
    extra = sorted(set(jobs) - set(want))
    also = f"; also scraped, not in this check's list: {', '.join(extra)}" if extra else ""
    if wrong:
        say("FAIL", f"targets: expected jobs/target counts differ: {'; '.join(wrong)}{also}")
    else:
        say("OK", f"targets: all {len(want)} expected jobs present with their target counts{also}")


def alert_path():
    ams = prom("alertmanagers")["activeAlertmanagers"]
    if ams:
        say("OK", f"alert path: Prometheus sends to {', '.join(a['url'] for a in ams)}")
    else:
        say("FAIL", "alert path: Prometheus has no active Alertmanager")
    _, body = fetch(AM + "/api/v2/alerts?active=true&silenced=false&inhibited=false&unprocessed=false")
    alerts = json.loads(body)
    if any(a["labels"].get("alertname") == "Watchdog" for a in alerts):
        say("OK", "alert path: Watchdog active in Alertmanager (Prometheus to Alertmanager works)")
    else:
        say("FAIL", "alert path: Watchdog missing from Alertmanager, so alerting itself is broken")
    others = sorted(f"{a['labels'].get('alertname', '?')} ({a['labels'].get('instance', '-')})"
                    for a in alerts if a["labels"].get("alertname") != "Watchdog")
    if others:
        say("FAIL", f"alerts firing: {', '.join(others)}")
    else:
        say("OK", "alerts: nothing firing besides Watchdog")


def healthcheck():
    ages = {host_of(r["metric"].get("instance", "")): float(r["value"][1])
            for r in query("time() - beamline_healthcheck_last_run_timestamp_seconds")}
    missing = [h for h in fleet if h not in ages]
    old = [f"{h} ({ages[h]:.0f}s)" for h in fleet if h in ages and ages[h] > stale]
    if missing:
        say("FAIL", f"health check: no results from {', '.join(missing)}")
    if old:
        say("FAIL", f"health check: older than {stale:.0f}s on {', '.join(old)}")
    if not missing and not old:
        say("OK", f"health check: all {len(fleet)} hosts report, oldest run {max(ages[h] for h in fleet):.0f}s ago")
    failing = sorted(f"{host_of(r['metric'].get('instance', ''))}:{r['metric'].get('check', '?')}"
                     for r in query("beamline_healthcheck_check_ok == 0"))
    if failing:
        say("FAIL", f"health check: failing checks: {', '.join(failing)}")
    else:
        say("OK", "health check: every check passes on every reporting host")


if not fleet:
    say("CANNOT", "no fleet hosts were passed to the queries")
    sys.exit(0)
readiness()
for name, fn in (("prometheus config/rules", config_and_rules), ("targets", targets),
                 ("alert path", alert_path), ("health check", healthcheck)):
    try:
        fn()
    except (OSError, ValueError, KeyError, IndexError, RuntimeError) as exc:
        say("CANNOT", f"{name}: {type(exc).__name__}: {exc}")
PY
)
rc=0
out=$(fleet_ssh "$HOST" "echo $remote | base64 -d | python3 -I - $STALE ${hosts[*]}" 2>&1) || rc=$?
if (( rc == 255 )); then
  fleet_check_cannot "ssh to $HOST failed: ${out:0:300}"
else
  n=0
  while IFS='|' read -r kind msg; do
    case $kind in
      OK) fleet_check_ok "$msg"; n=$(( n + 1 )) ;;
      FAIL) fleet_check_fail "$msg"; n=$(( n + 1 )) ;;
      CANNOT) fleet_check_cannot "$msg"; n=$(( n + 1 )) ;;
    esac
  done <<< "$out"
  if (( rc != 0 || n == 0 )); then
    fleet_check_cannot "queries on $HOST exited $rc with $n verdict(s); last output: $(tail -n 2 <<< "$out" | tr '\n' ' ')"
  fi
fi

# 2. Grafana, from here, over TLS verified against this host's trust store.
body=$(mktemp)
trap 'rm -f "$body"' EXIT
IFS='|' read -r code cexit cerr < <(curl -s -o "$body" --connect-timeout 5 --max-time 10 \
  -w '%{http_code}|%{exitcode}|%{errormsg}\n' "$GRAFANA")
if [[ ${cexit:-x} != 0 ]]; then
  fleet_check_fail "grafana: $GRAFANA -> no answer (curl exit ${cexit:-?}: ${cerr:-})"
elif [[ $code != 200 ]]; then
  fleet_check_fail "grafana: $GRAFANA -> HTTP $code (want 200)"
elif [[ $(jq -r '.database // empty' "$body" 2>/dev/null) == ok ]]; then
  fleet_check_ok "grafana: $GRAFANA -> 200 over verified TLS, database ok, version $(jq -r '.version // "?"' "$body")"
else
  fleet_check_fail "grafana: $GRAFANA -> 200 but database is '$(jq -r '.database // "?"' "$body" 2>/dev/null)' (want ok)"
fi

# 3. Prometheus and Alertmanager are loopback-only on obs: from here they must
#    not answer (refused or dropped); an HTTP answer of any kind is exposure.
for port in 9090 9093; do
  IFS='|' read -r code cexit cerr < <(curl -s -o /dev/null --connect-timeout 3 --max-time 5 \
    -w '%{http_code}|%{exitcode}|%{errormsg}\n' "http://$HOST:$port/-/ready")
  case ${cexit:-x} in
    7|28) fleet_check_ok "exposure: $HOST:$port does not answer from here (curl exit $cexit)" ;;
    0) fleet_check_fail "exposure: $HOST:$port answered HTTP $code from here; want loopback only" ;;
    *) fleet_check_cannot "exposure: $HOST:$port -> curl exit ${cexit:-?}: ${cerr:-}" ;;
  esac
done

# 4. GitLab's metrics, as seen from here (not obs): the Workhorse, Gitaly and nginx
#    status ports must not answer, and Rails must refuse /-/metrics with 404.
for port in 9229 9236 8060; do
  IFS='|' read -r code cexit cerr < <(curl -s -o /dev/null --connect-timeout 3 --max-time 5 \
    -w '%{http_code}|%{exitcode}|%{errormsg}\n' "http://$GITLAB:$port/metrics")
  case ${cexit:-x} in
    7|28) fleet_check_ok "exposure: $GITLAB:$port does not answer from here (curl exit $cexit)" ;;
    0) fleet_check_fail "exposure: $GITLAB:$port answered HTTP $code from here; want obs only" ;;
    *) fleet_check_cannot "exposure: $GITLAB:$port -> curl exit ${cexit:-?}: ${cerr:-}" ;;
  esac
done
IFS='|' read -r code cexit cerr < <(curl -s -o /dev/null --connect-timeout 5 --max-time 10 \
  -w '%{http_code}|%{exitcode}|%{errormsg}\n' "https://$GITLAB/-/metrics")
if [[ ${cexit:-x} != 0 ]]; then
  fleet_check_cannot "exposure: https://$GITLAB/-/metrics -> no answer (curl exit ${cexit:-?}: ${cerr:-})"
elif [[ $code == 404 ]]; then
  fleet_check_ok "exposure: https://$GITLAB/-/metrics -> 404 from here (monitoring_whitelist admits obs only)"
elif [[ $code == 200 ]]; then
  fleet_check_fail "exposure: https://$GITLAB/-/metrics -> 200 from here; want 404 (obs only)"
else
  fleet_check_cannot "exposure: https://$GITLAB/-/metrics -> HTTP $code; want 404"
fi

fleet_check_exit
