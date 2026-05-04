#!/usr/bin/env bash
# Purpose: Create Backstage + Argo CD GitHub Apps in mycnoeorg using Backstage CLI,
#          install them on the fork, and materialize private/*.yaml files.
# Usage:   ./scripts/create-github-apps.sh
# Prereqs: npx/node installed; run from repo root; GH_TOKEN exported.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORG="mycnoeorg"
FORK="reference-implementation-aws"
WORK_DIR="$(mktemp -d)"

cd "$WORK_DIR"

echo "[create-github-apps] Working dir: $WORK_DIR"
echo "[create-github-apps] Creating Backstage GitHub App — browser will open."
echo "  > Accept defaults, set name like 'cnoe-backstage-<suffix>', complete in browser."
npx --yes @backstage/cli create-github-app "$ORG"

echo
echo "[create-github-apps] Creating Argo CD GitHub App — browser will open."
echo "  > Accept defaults, set name like 'cnoe-argocd-<suffix>', complete in browser."
npx --yes @backstage/cli create-github-app "$ORG"

echo
echo "[create-github-apps] Generated files:"
ls -la github-app-*-credentials.yaml

# The backstage-cli names files github-app-<app-name>-credentials.yaml.
# We assume the FIRST created was Backstage and SECOND was Argo CD.
# Sort by mtime ascending.
mapfile -t FILES < <(ls -t github-app-*-credentials.yaml | tac)
BACKSTAGE_CRED="${FILES[0]}"
ARGOCD_CRED="${FILES[1]}"

echo "[create-github-apps] Backstage credentials: $BACKSTAGE_CRED"
echo "[create-github-apps] Argo CD  credentials:  $ARGOCD_CRED"

# --- Build private/backstage-github.yaml ---
# Backstage cred file already has the right shape (appId, webhookUrl, clientId,
# clientSecret, webhookSecret, privateKey). Copy as-is.
cp "$BACKSTAGE_CRED" "$REPO_ROOT/private/backstage-github.yaml"

# --- Build private/argocd-github.yaml ---
# Argo CD needs: url, appId, installationId, privateKey
# Derive installationId from /orgs/$ORG/installations
ARGOCD_APP_ID=$(yq '.appId' "$ARGOCD_CRED")
ARGOCD_PRIV_KEY=$(yq '.privateKey' "$ARGOCD_CRED")

echo "[create-github-apps] Fetching Argo CD app installationId from org $ORG..."
# List installations for the org; find the one whose app_id matches ARGOCD_APP_ID
INSTALLATION_ID=$(gh api "/orgs/$ORG/installations" \
  --jq ".installations[] | select(.app_id == $ARGOCD_APP_ID) | .id" | head -1)

if [ -z "$INSTALLATION_ID" ]; then
  echo "[create-github-apps] ERROR: Could not find installation for app_id=$ARGOCD_APP_ID in org $ORG."
  echo "  > Confirm the app was installed on the org (not just created). Install it here:"
  echo "    https://github.com/organizations/$ORG/settings/installations"
  exit 1
fi
echo "[create-github-apps] Argo CD installationId: $INSTALLATION_ID"

# Write argocd-github.yaml with correct keys
yq -n \
  --arg url "https://github.com/$ORG" \
  --arg appId "$ARGOCD_APP_ID" \
  --arg installationId "$INSTALLATION_ID" \
  --arg privateKey "$ARGOCD_PRIV_KEY" \
  '.url = $url | .appId = $appId | .installationId = $installationId | .privateKey = $privateKey' \
  > "$REPO_ROOT/private/argocd-github.yaml" 2>/dev/null \
  || {
    # yq (mikefarah) doesn't support --arg; fall back to raw printf
    {
      printf 'url: "https://github.com/%s"\n' "$ORG"
      printf 'appId: "%s"\n' "$ARGOCD_APP_ID"
      printf 'installationId: "%s"\n' "$INSTALLATION_ID"
      printf 'privateKey: |\n'
      printf '%s\n' "$ARGOCD_PRIV_KEY" | sed 's/^/  /'
    } > "$REPO_ROOT/private/argocd-github.yaml"
  }

echo
echo "[create-github-apps] Done. Files written:"
ls -la "$REPO_ROOT/private/"*.yaml
echo
echo "[create-github-apps] IMPORTANT: install BOTH apps on your fork $ORG/$FORK:"
echo "  https://github.com/organizations/$ORG/settings/installations"
echo "  -> For each app: Configure -> Repository access -> Only select repositories -> $FORK"
