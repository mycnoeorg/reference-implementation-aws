#!/usr/bin/env bash
# Purpose: Disable External DNS by removing the external-dns ApplicationSet
#          and scaling the deployment to 0, then deleting DNS records.
# Usage: ./scripts/disable-external-dns.sh
# Prerequisites: kubectl (context: cnoe-ref-impl), aws CLI, AWS_PROFILE=hubcnoe
set -euo pipefail

KUBE_CONTEXT="cnoe-ref-impl"
HOSTED_ZONE_ID="Z0125447F67JOS1JXD20"
DOMAIN="pcsilva.people.aws.dev"
AWS_PROFILE="${AWS_PROFILE:-hubcnoe}"

echo "[disable-external-dns] Starting..."

# Step 1: Delete the External DNS ApplicationSet (stops ArgoCD from recreating the app)
echo "[disable-external-dns] Deleting External DNS ApplicationSet..."
kubectl --context="$KUBE_CONTEXT" -n argocd delete applicationset external-dns --cascade=orphan 2>/dev/null || true

# Step 2: Delete the External DNS Application (with cascade=orphan to keep the namespace)
echo "[disable-external-dns] Removing auto-sync from External DNS Application..."
kubectl --context="$KUBE_CONTEXT" -n argocd patch application external-dns-cnoe-ref-impl \
  --type=json -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || true

# Step 3: Scale down External DNS
echo "[disable-external-dns] Scaling External DNS to 0..."
kubectl --context="$KUBE_CONTEXT" -n external-dns scale deploy/external-dns --replicas=0

# Step 4: Wait for pods to terminate
echo "[disable-external-dns] Waiting for pods to terminate..."
kubectl --context="$KUBE_CONTEXT" -n external-dns wait --for=delete pod -l app.kubernetes.io/name=external-dns --timeout=30s 2>/dev/null || true

# Step 5: Delete DNS records
echo "[disable-external-dns] Deleting DNS records from Route53..."

# Get current A/AAAA records
for TYPE in A AAAA; do
  RECORD=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --profile "$AWS_PROFILE" \
    --query "ResourceRecordSets[?Name=='${DOMAIN}.' && Type=='${TYPE}']" \
    --output json 2>/dev/null)

  if echo "$RECORD" | python3 -c "import json,sys; r=json.load(sys.stdin); exit(0 if len(r)>0 else 1)" 2>/dev/null; then
    CHANGE=$(echo "$RECORD" | python3 -c "
import json,sys
r = json.load(sys.stdin)[0]
print(json.dumps({'Changes':[{'Action':'DELETE','ResourceRecordSet':r}]}))
")
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$HOSTED_ZONE_ID" \
      --change-batch "$CHANGE" \
      --profile "$AWS_PROFILE" \
      --output text 2>/dev/null || true
    echo "  Deleted $TYPE record"
  else
    echo "  No $TYPE record found (already deleted)"
  fi
done

# Delete TXT record
TXT_RECORD=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --profile "$AWS_PROFILE" \
  --query "ResourceRecordSets[?Name=='${DOMAIN}.' && Type=='TXT']" \
  --output json 2>/dev/null)

if echo "$TXT_RECORD" | python3 -c "import json,sys; r=json.load(sys.stdin); exit(0 if len(r)>0 else 1)" 2>/dev/null; then
  CHANGE=$(echo "$TXT_RECORD" | python3 -c "
import json,sys
r = json.load(sys.stdin)[0]
print(json.dumps({'Changes':[{'Action':'DELETE','ResourceRecordSet':r}]}))
")
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "$CHANGE" \
    --profile "$AWS_PROFILE" \
    --output text 2>/dev/null || true
  echo "  Deleted TXT record"
fi

# Step 6: Verify
echo "[disable-external-dns] Verifying..."
sleep 3
REMAINING=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --profile "$AWS_PROFILE" \
  --query "ResourceRecordSets[?Name=='${DOMAIN}.' && (Type=='A' || Type=='AAAA')].Type" \
  --output text 2>/dev/null || true)

if [ -z "$REMAINING" ]; then
  echo "[disable-external-dns] ✅ All A/AAAA records removed"
else
  echo "[disable-external-dns] ⚠️  Records still present: $REMAINING"
fi

REPLICAS=$(kubectl --context="$KUBE_CONTEXT" -n external-dns get deploy external-dns -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "N/A")
echo "[disable-external-dns] External DNS replicas: $REPLICAS"

echo "[disable-external-dns] Done."
