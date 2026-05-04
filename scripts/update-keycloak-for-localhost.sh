#!/usr/bin/env bash
# Purpose: Update Keycloak OIDC clients to accept localhost redirect URIs
#          for port-forward access. Adds localhost URIs alongside existing ones.
# Usage: ./scripts/update-keycloak-for-localhost.sh
# Prerequisites: kubectl (context: cnoe-ref-impl), .env with KEYCLOAK_ADMIN_PASSWORD
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load credentials from .env (not committed)
if [ -f "$PROJECT_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.env"
  set +a
fi

if [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: KEYCLOAK_ADMIN_PASSWORD not set. Copy .env.example to .env and fill it in." >&2
  exit 1
fi

KUBE_CONTEXT="cnoe-ref-impl"
KCADM="/opt/bitnami/keycloak/bin/kcadm.sh"
KC_CONFIG="/tmp/kcadm.config"
REALM="cnoe"
KC_POD="keycloak-0"
KC_NS="keycloak"
KC_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-cnoe-admin}"

run_kc() {
  kubectl --context="$KUBE_CONTEXT" -n "$KC_NS" exec "$KC_POD" -- "$KCADM" "$@" --config "$KC_CONFIG" 2>&1 | grep -v "^Defaulted container"
}

echo "[keycloak-localhost] Starting..."

# Authenticate
echo "[keycloak-localhost] Authenticating to Keycloak..."
kubectl --context="$KUBE_CONTEXT" -n "$KC_NS" exec "$KC_POD" -- \
  "$KCADM" config credentials \
  --server http://localhost:8080/keycloak \
  --realm "$REALM" \
  --user "$KC_ADMIN_USER" \
  --password "$KEYCLOAK_ADMIN_PASSWORD" \
  --config "$KC_CONFIG" 2>&1 | grep -v "^Defaulted container"

# --- Update backstage client ---
echo "[keycloak-localhost] Updating backstage client..."
BACKSTAGE_ID=$(run_kc get clients -r "$REALM" --fields id,clientId | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c['clientId']=='backstage': print(c['id'])
")
run_kc update "clients/$BACKSTAGE_ID" -r "$REALM" \
  -s 'redirectUris=["https://pcsilva.people.aws.dev/api/auth/keycloak-oidc/handler/frame","http://localhost:7007/api/auth/keycloak-oidc/handler/frame"]' \
  -s 'webOrigins=["https://pcsilva.people.aws.dev","http://localhost:7007"]'
echo "  ✅ backstage: added http://localhost:7007 redirects"

# --- Update argocd client ---
echo "[keycloak-localhost] Updating argocd client..."
ARGOCD_ID=$(run_kc get clients -r "$REALM" --fields id,clientId | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c['clientId']=='argocd': print(c['id'])
")
run_kc update "clients/$ARGOCD_ID" -r "$REALM" \
  -s 'redirectUris=["https://pcsilva.people.aws.dev/argocd/pkce/verify","https://pcsilva.people.aws.dev/argocd/auth/callback","http://localhost:8085/auth/callback","https://localhost:8080/argocd/pkce/verify","https://localhost:8080/argocd/auth/callback","https://localhost:8080/pkce/verify","https://localhost:8080/auth/callback"]' \
  -s 'webOrigins=["https://pcsilva.people.aws.dev/argocd","https://localhost:8080"]'
echo "  ✅ argocd: added https://localhost:8080 redirects"

# --- Update argo-workflows client ---
echo "[keycloak-localhost] Updating argo-workflows client..."
ARGO_WF_ID=$(run_kc get clients -r "$REALM" --fields id,clientId | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c['clientId']=='argo-workflows': print(c['id'])
")
run_kc update "clients/$ARGO_WF_ID" -r "$REALM" \
  -s 'redirectUris=["https://pcsilva.people.aws.dev/argo-workflows/oauth2/callback","https://localhost:2746/oauth2/callback"]' \
  -s 'webOrigins=["https://pcsilva.people.aws.dev/argo-workflows","https://localhost:2746"]'
echo "  ✅ argo-workflows: added https://localhost:2746 redirects"

# --- Update Keycloak hostname to allow localhost ---
echo "[keycloak-localhost] Done. Keycloak clients updated for localhost access."
echo ""
echo "NOTE: Keycloak itself has KEYCLOAK_HOSTNAME=https://pcsilva.people.aws.dev/keycloak/"
echo "For SSO to work via localhost, you need to add to /etc/hosts:"
echo "  127.0.0.1  pcsilva.people.aws.dev"
echo "OR update the Keycloak deployment to use a localhost-compatible hostname."
