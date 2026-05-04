#!/usr/bin/env bash
# Purpose: Create a GCP service account for provider-terraform and store
#          its key as a Kubernetes secret + ProviderConfig for GCP workspaces.
# Usage: ./scripts/setup-gcp-credentials.sh
# Prerequisites: gcloud CLI, kubectl, GCP project cksexam-482820
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Configuration ---
GCP_PROJECT="${GCP_PROJECT:-cksexam-482820}"
SA_NAME="crossplane-tf-demo"
SA_EMAIL="${SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com"
K8S_SECRET_NAME="gcp-tf-credentials"
K8S_NAMESPACE="crossplane-system"
PROVIDER_CONFIG_NAME="gcp"
KEY_FILE="/tmp/gcp-tf-demo-key.json"

echo "[setup-gcp-credentials] Starting..."

# 1. Create the service account if it doesn't exist
if gcloud iam service-accounts describe "$SA_EMAIL" --project "$GCP_PROJECT" >/dev/null 2>&1; then
  echo "[setup-gcp-credentials] SA $SA_EMAIL already exists"
else
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Crossplane Terraform Demo" \
    --project "$GCP_PROJECT"
  echo "[setup-gcp-credentials] Created SA: $SA_EMAIL"
fi

# 2. Grant Pub/Sub Admin role (for creating topics/subscriptions)
gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/pubsub.admin" \
  --condition=None \
  --quiet >/dev/null 2>&1 || true
echo "[setup-gcp-credentials] Granted roles/pubsub.admin"

# 3. Generate a key (or reuse existing)
if kubectl -n "$K8S_NAMESPACE" get secret "$K8S_SECRET_NAME" >/dev/null 2>&1; then
  echo "[setup-gcp-credentials] K8s secret $K8S_SECRET_NAME already exists, skipping key generation"
else
  gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$SA_EMAIL" \
    --project "$GCP_PROJECT"
  echo "[setup-gcp-credentials] Generated key at $KEY_FILE"

  # 4. Create Kubernetes secret
  kubectl -n "$K8S_NAMESPACE" create secret generic "$K8S_SECRET_NAME" \
    --from-file=credentials.json="$KEY_FILE"
  echo "[setup-gcp-credentials] Created K8s secret $K8S_SECRET_NAME"

  # Clean up local key file
  rm -f "$KEY_FILE"
fi

# 5. Create ProviderConfig for GCP Terraform workspaces
cat <<YAML | kubectl apply -f -
apiVersion: tf.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: ${PROVIDER_CONFIG_NAME}
spec:
  configuration: |
    terraform {
      backend "kubernetes" {
        secret_suffix     = "providerconfig-${PROVIDER_CONFIG_NAME}"
        namespace         = "${K8S_NAMESPACE}"
        in_cluster_config = true
      }
    }
  credentials:
    - filename: gcp-credentials.json
      source: Secret
      secretRef:
        namespace: ${K8S_NAMESPACE}
        name: ${K8S_SECRET_NAME}
        key: credentials.json
  pluginCache: true
YAML

echo "[setup-gcp-credentials] Created/updated ProviderConfig '$PROVIDER_CONFIG_NAME'"
echo "[setup-gcp-credentials] Done."
