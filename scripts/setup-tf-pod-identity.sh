#!/usr/bin/env bash
# Purpose: Create EKS Pod Identity association for provider-terraform SA
#          so Terraform Workspaces can provision real AWS resources.
# Usage: ./scripts/setup-tf-pod-identity.sh
# Prerequisites: aws CLI, kubectl, AWS_PROFILE=hubcnoe, AWS_REGION=us-west-1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Configuration ---
CLUSTER_NAME="${CLUSTER_NAME:-cnoe-ref-impl}"
AWS_REGION="${AWS_REGION:-us-west-1}"
AWS_PROFILE="${AWS_PROFILE:-hubcnoe}"
NAMESPACE="crossplane-system"

echo "[setup-tf-pod-identity] Starting..."

# 1. Discover the provider-terraform service account name
TF_SA=$(kubectl -n "$NAMESPACE" get sa -o name | grep terraform | sed 's|serviceaccount/||')
if [ -z "$TF_SA" ]; then
  echo "ERROR: No provider-terraform service account found in $NAMESPACE"
  exit 1
fi
echo "[setup-tf-pod-identity] Found SA: $TF_SA"

# 2. Check if a Pod Identity association already exists for this SA
EXISTING=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --query "associations[?serviceAccount=='$TF_SA' && namespace=='$NAMESPACE'].associationId" \
  --output text 2>/dev/null || true)

if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  echo "[setup-tf-pod-identity] Pod Identity association already exists: $EXISTING"
  echo "[setup-tf-pod-identity] Done (no changes needed)."
  exit 0
fi

# 3. Discover the IAM role used by provider-aws (reuse the same role)
PROVIDER_AWS_ASSOC_ID=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --query "associations[?serviceAccount=='provider-aws' && namespace=='$NAMESPACE'].associationId" \
  --output text)

if [ -z "$PROVIDER_AWS_ASSOC_ID" ] || [ "$PROVIDER_AWS_ASSOC_ID" = "None" ]; then
  echo "ERROR: No Pod Identity association found for provider-aws. Cannot determine IAM role."
  exit 1
fi

ROLE_ARN=$(aws eks describe-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" \
  --association-id "$PROVIDER_AWS_ASSOC_ID" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --query "association.roleArn" \
  --output text)

echo "[setup-tf-pod-identity] Reusing IAM role: $ROLE_ARN"

# 4. Create the Pod Identity association
aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --service-account "$TF_SA" \
  --role-arn "$ROLE_ARN" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --tags "key=purpose,value=provider-terraform-demo"

echo "[setup-tf-pod-identity] Created Pod Identity association for $TF_SA"

# 5. Restart the provider-terraform pod to pick up the new credentials
TF_DEPLOY=$(kubectl -n "$NAMESPACE" get deploy -o name | grep terraform)
if [ -n "$TF_DEPLOY" ]; then
  kubectl -n "$NAMESPACE" rollout restart "$TF_DEPLOY"
  echo "[setup-tf-pod-identity] Restarted $TF_DEPLOY to pick up credentials"
  kubectl -n "$NAMESPACE" rollout status "$TF_DEPLOY" --timeout=120s
fi

echo "[setup-tf-pod-identity] Done."
