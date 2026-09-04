#!/usr/bin/env bash
set -uo pipefail

print_usage() {
  cat <<'USAGE'
Usage: fleet-check.sh

Run a multi-domain health check across the beamline platform: GitLab
(web UI, registry, runner), Ansible configuration drift, Kubernetes
node/pod health, Argo CD app sync status, Podman, package mirrors, and
the Prometheus/Grafana/Alertmanager observability stack.

Options:
  -h, --help    Show this help message and exit

Takes no other arguments. Prints a [OK]/[FAIL] line per check.
Exit code: 0 if every check passed, 1 if any check failed.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) print_usage; exit 0 ;;
  esac
done

# shellcheck source=./fleet.conf
source "$(dirname "${BASH_SOURCE[0]}")/fleet.conf"
export LIBVIRT_DEFAULT_URI="qemu:///system"

ssh_vm() {
  local host="$1"; shift
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "$SSH_USER@$host" "$@"
}

FAILURES=0
pass() { echo "  [OK]   $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

echo "=== GitLab (gitlab.beamline) ==="
if curl -sf http://gitlab.beamline/-/health >/dev/null 2>&1; then pass "web UI health endpoint"; else fail "web UI health endpoint"; fi
if curl -sf http://gitlab.beamline:5050/v2/ >/dev/null 2>&1; then pass "container registry"; else fail "container registry (check port)"; fi
if ssh_vm gitlab.beamline "sudo gitlab-runner status" 2>&1 | grep -qi running; then pass "gitlab-runner"; else fail "gitlab-runner"; fi

echo ""
echo "=== Ansible drift (from admin.beamline) ==="
DRIFT=$(ssh_vm admin.beamline "cd ~/lab-ansible && ansible-playbook site.yml --check 2>&1")
if echo "$DRIFT" | grep -q "failed=0" && echo "$DRIFT" | grep -qE "changed=0"; then
  pass "no drift detected"
else
  fail "drift or failures detected -- review output:"
  echo "$DRIFT" | tail -20
fi

echo ""
echo "=== Kubernetes cluster (k8cp.beamline) ==="
if ! NODES=$(ssh_vm k8cp.beamline "kubectl get nodes --no-headers" 2>&1); then
  fail "could not reach k8cp.beamline via SSH"
elif echo "$NODES" | grep -qv "Ready" ; then
  fail "one or more nodes not Ready:"; echo "$NODES"
else
  pass "all nodes Ready"
fi
if ! BADPODS=$(ssh_vm k8cp.beamline "kubectl get pods -A --no-headers" 2>&1); then
  fail "could not reach k8cp.beamline via SSH"
elif echo "$BADPODS" | grep -qvE "Running|Completed"; then
  fail "pods not Running/Completed:"; echo "$BADPODS" | grep -vE "Running|Completed"
else
  pass "all pods healthy"
fi

echo ""
echo "=== Argo CD app sync status (k8cp.beamline) ==="
if ! ARGO=$(ssh_vm k8cp.beamline "kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers" 2>&1); then
  fail "could not reach k8cp.beamline via SSH"
elif echo "$ARGO" | grep -qvE "Synced\s+Healthy"; then
  fail "app(s) not Synced/Healthy:"; echo "$ARGO"
else
  pass "all apps Synced/Healthy"
fi

echo ""
echo "=== Podman (pkg.beamline) ==="
if ssh_vm pkg.beamline "podman info" >/dev/null 2>&1; then pass "podman responsive"; else fail "podman not responsive or host unreachable"; fi

echo ""
echo "=== pkg.beamline repo servers ==="
if curl -sf http://pkg.beamline/deb/ >/dev/null 2>&1; then pass "apt (deb) repo server"; else fail "apt (deb) repo server (check path/port)"; fi
if curl -sf http://pkg.beamline/conda/ >/dev/null 2>&1; then pass "conda channel server"; else fail "conda channel server (check path/port)"; fi

echo ""
echo "=== Observability stack (obs.beamline) ==="
if curl -sf http://obs.beamline:9090/-/healthy >/dev/null 2>&1; then pass "Prometheus"; else fail "Prometheus (check port)"; fi
if curl -sf http://obs.beamline:3000/api/health >/dev/null 2>&1; then pass "Grafana"; else fail "Grafana (check port)"; fi
if curl -sf http://obs.beamline:9093/-/healthy >/dev/null 2>&1; then pass "Alertmanager"; else fail "Alertmanager (check port)"; fi

echo ""
echo "=== beamline-healthcheck (Prometheus textfile collector) ==="
if ssh_vm pkg.beamline "systemctl is-active --quiet beamline-healthcheck.timer" >/dev/null 2>&1; then pass "systemd timer active"; else fail "systemd timer not active or host unreachable"; fi

echo ""
echo "=== Done ==="
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed"
  exit 1
fi
exit 0
