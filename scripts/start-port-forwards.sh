#!/usr/bin/env bash
# Purpose: Start port-forward to ingress-nginx for local demo access.
#          Combined with /etc/hosts entry (127.0.0.1 pcsilva.people.aws.dev),
#          all services remain accessible at the same URLs as before.
# Usage: ./scripts/start-port-forwards.sh
# Prerequisites: kubectl (context: cnoe-ref-impl), /etc/hosts entry
# Stop: ./scripts/stop-port-forwards.sh
set -euo pipefail

KUBE_CONTEXT="cnoe-ref-impl"
PID_FILE="/tmp/cnoe-pf-pids.txt"

echo "[port-forward] Starting port-forward sessions..."

# Kill any existing port-forwards from a previous run
if [ -f "$PID_FILE" ]; then
  echo "[port-forward] Stopping previous port-forward sessions..."
  while read -r pid; do
    kill "$pid" 2>/dev/null || true
  done < "$PID_FILE"
  rm -f "$PID_FILE"
  sleep 1
fi

# Check /etc/hosts
if ! grep -q "pcsilva.people.aws.dev" /etc/hosts 2>/dev/null; then
  echo ""
  echo "⚠️  /etc/hosts entry not found. Run:"
  echo "   sudo bash -c 'echo \"127.0.0.1  pcsilva.people.aws.dev\" >> /etc/hosts'"
  echo ""
fi

# Port-forward ingress-nginx on 443 (HTTPS) — all services via path routing
# Requires sudo because port 443 is privileged
echo "[port-forward] Forwarding ingress-nginx (HTTPS on port 443)..."
sudo -E kubectl --context="$KUBE_CONTEXT" port-forward -n ingress-nginx svc/ingress-nginx-controller 443:443 > /dev/null 2>&1 &
echo $! >> "$PID_FILE"
echo "  ✅ ingress-nginx → https://pcsilva.people.aws.dev (port 443)"

# Also forward port 80 for HTTP redirects
sudo -E kubectl --context="$KUBE_CONTEXT" port-forward -n ingress-nginx svc/ingress-nginx-controller 80:80 > /dev/null 2>&1 &
echo $! >> "$PID_FILE"
echo "  ✅ ingress-nginx → http://pcsilva.people.aws.dev  (port 80)"

echo ""
echo "[port-forward] All sessions started. PIDs saved to $PID_FILE"
echo ""
echo "Access services at:"
echo "  Backstage:      https://pcsilva.people.aws.dev"
echo "  ArgoCD:         https://pcsilva.people.aws.dev/argocd"
echo "  Keycloak:       https://pcsilva.people.aws.dev/keycloak/admin/"
echo "  Argo Workflows: https://pcsilva.people.aws.dev/argo-workflows"
echo ""
echo "To stop: ./scripts/stop-port-forwards.sh"
