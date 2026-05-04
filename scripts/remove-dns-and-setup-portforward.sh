#!/usr/bin/env bash
# Purpose: Remove DNS records from Route53, scale down External DNS,
#          and prepare the environment for port-forward access.
# Usage: ./scripts/remove-dns-and-setup-portforward.sh
# Prerequisites: aws CLI, kubectl (context: cnoe-ref-impl), AWS_PROFILE=hubcnoe
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Configuration ---
HOSTED_ZONE_ID="Z0125447F67JOS1JXD20"
DOMAIN="pcsilva.people.aws.dev"
NLB_DNS="cnoe-56df4a6da3dc8d05.elb.us-west-1.amazonaws.com"
NLB_HOSTED_ZONE="Z24FKFUX50B4VW"
AWS_REGION="${AWS_REGION:-us-west-1}"
AWS_PROFILE="${AWS_PROFILE:-hubcnoe}"
KUBE_CONTEXT="cnoe-ref-impl"

echo "[remove-dns] Starting..."

# --- Step 1: Scale down External DNS to prevent record recreation ---
echo "[remove-dns] Scaling External DNS to 0 replicas..."
kubectl --context="$KUBE_CONTEXT" -n external-dns scale deploy/external-dns --replicas=0
kubectl --context="$KUBE_CONTEXT" -n external-dns rollout status deploy/external-dns --timeout=30s 2>/dev/null || true
echo "[remove-dns] External DNS scaled to 0"

# --- Step 2: Get the NLB hosted zone ID for alias records ---
echo "[remove-dns] Looking up NLB hosted zone ID..."
NLB_HOSTED_ZONE=$(aws elbv2 describe-load-balancers \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --query "LoadBalancers[?DNSName=='${NLB_DNS}'].CanonicalHostedZoneId" \
  --output text 2>/dev/null || echo "Z24FKFUX50B4VW")
echo "[remove-dns] NLB hosted zone: $NLB_HOSTED_ZONE"

# --- Step 3: Delete A, AAAA, and TXT records ---
echo "[remove-dns] Deleting DNS records..."

CHANGE_BATCH=$(cat <<EOF
{
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}.",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${NLB_HOSTED_ZONE}",
          "DNSName": "${NLB_DNS}.",
          "EvaluateTargetHealth": true
        }
      }
    },
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}.",
        "Type": "AAAA",
        "AliasTarget": {
          "HostedZoneId": "${NLB_HOSTED_ZONE}",
          "DNSName": "${NLB_DNS}.",
          "EvaluateTargetHealth": true
        }
      }
    },
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}.",
        "Type": "TXT",
        "TTL": 300,
        "ResourceRecords": [
          {"Value": "\"heritage=external-dns,external-dns/owner=cnoe-external-dns,external-dns/resource=ingress/argo/argo-workflows-server\""}
        ]
      }
    }
  ]
}
EOF
)

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$CHANGE_BATCH" \
  --profile "$AWS_PROFILE" \
  --output text 2>&1 || echo "[remove-dns] WARNING: Some records may have already been deleted"

echo "[remove-dns] DNS records deleted"

# --- Step 4: Verify ---
echo "[remove-dns] Verifying records are gone..."
REMAINING=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --profile "$AWS_PROFILE" \
  --query "ResourceRecordSets[?Name=='${DOMAIN}.' && (Type=='A' || Type=='AAAA')].Type" \
  --output text 2>/dev/null || true)

if [ -z "$REMAINING" ]; then
  echo "[remove-dns] ✅ A/AAAA records successfully removed"
else
  echo "[remove-dns] ⚠️  Some records still present: $REMAINING (may take a moment to propagate)"
fi

echo "[remove-dns] Done. DNS records removed, External DNS scaled to 0."
echo ""
echo "Next steps:"
echo "  1. Add to /etc/hosts:  127.0.0.1  pcsilva.people.aws.dev"
echo "  2. Run ./scripts/start-port-forwards.sh to start port-forward sessions"
echo "  3. Access services at the same URLs as before (via /etc/hosts + port-forward)"
