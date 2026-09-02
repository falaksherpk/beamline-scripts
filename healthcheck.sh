#!/usr/bin/env bash
set -uo pipefail
export LIBVIRT_DEFAULT_URI="qemu:///system"

ssh_vm() {
  local ip="$1"; shift
  ssh -i ~/.ssh/beamline_vms -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes falak@"$ip" "$@"
}

pass() { echo "  [OK]   $1"; }
fail() { echo "  [FAIL] $1"; }

echo "=== GitLab (gitlab.beamline) ==="
if curl -sf http://10.10.10.12/-/health >/dev/null 2>&1; then pass "web UI health endpoint"; else fail "web UI health endpoint"; fi
if curl -sf http://10.10.10.12:5050/v2/ >/dev/null 2>&1; then pass "container registry"; else fail "container registry (check port)"; fi
if ssh_vm 10.10.10.12 "sudo gitlab-runner status" 2>&1 | grep -qi running; then pass "gitlab-runner"; else fail "gitlab-runner"; fi

echo ""
echo "=== Ansible drift (from admin.beamline) ==="
DRIFT=$(ssh_vm 10.10.10.11 "cd ~/lab-ansible && ansible-playbook site.yml --check 2>&1")
if echo "$DRIFT" | grep -q "failed=0" && echo "$DRIFT" | grep -qE "changed=0"; then
  pass "no drift detected"
else
  fail "drift or failures detected -- review output:"
  echo "$DRIFT" | tail -20
fi

echo ""
echo "=== Kubernetes cluster (k8cp.beamline) ==="
NODES=$(ssh_vm 10.10.10.21 "kubectl get nodes --no-headers 2>&1")
if echo "$NODES" | grep -qv "Ready" ; then fail "one or more nodes not Ready:"; echo "$NODES"; else pass "all nodes Ready"; fi
BADPODS=$(ssh_vm 10.10.10.21 "kubectl get pods -A --no-headers 2>&1 | grep -vE 'Running|Completed'")
if [ -n "$BADPODS" ]; then fail "pods not Running/Completed:"; echo "$BADPODS"; else pass "all pods healthy"; fi

echo ""
echo "=== Argo CD app sync status (k8cp.beamline) ==="
ARGO=$(ssh_vm 10.10.10.21 "kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers 2>&1")
if echo "$ARGO" | grep -qvE "Synced\s+Healthy"; then fail "app(s) not Synced/Healthy:"; echo "$ARGO"; else pass "all apps Synced/Healthy"; fi

echo ""
echo "=== Podman (pkg.beamline) ==="
if ssh_vm 10.10.10.13 "podman info" >/dev/null 2>&1; then pass "podman responsive"; else fail "podman not responsive"; fi

echo ""
echo "=== pkg.beamline repo servers ==="
if curl -sf http://10.10.10.13/deb/ >/dev/null 2>&1; then pass "apt (deb) repo server"; else fail "apt (deb) repo server (check path/port)"; fi
if curl -sf http://10.10.10.13/conda/ >/dev/null 2>&1; then pass "conda channel server"; else fail "conda channel server (check path/port)"; fi

echo ""
echo "=== Observability stack (obs.beamline) ==="
if curl -sf http://10.10.10.41:9090/-/healthy >/dev/null 2>&1; then pass "Prometheus"; else fail "Prometheus (check port)"; fi
if curl -sf http://10.10.10.41:3000/api/health >/dev/null 2>&1; then pass "Grafana"; else fail "Grafana (check port)"; fi
if curl -sf http://10.10.10.41:9093/-/healthy >/dev/null 2>&1; then pass "Alertmanager"; else fail "Alertmanager (check port)"; fi

echo ""
echo "=== beamline-healthcheck (Prometheus textfile collector) ==="
if ssh_vm 10.10.10.13 "systemctl is-active --quiet beamline-healthcheck.timer" 2>&1; then pass "systemd timer active"; else fail "systemd timer not active"; fi

echo ""
echo "=== Done ==="
