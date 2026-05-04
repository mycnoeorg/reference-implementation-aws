#!/usr/bin/env bash
# Purpose: Wait for all Terraform Workspaces to become Ready
# Usage: ./scripts/wait-tf-workspaces.sh
set -euo pipefail

MAX_CHECKS=30
SLEEP_INTERVAL=10

echo "[wait-tf-workspaces] Waiting for all Terraform Workspaces to become Ready..."

for i in $(seq 1 "$MAX_CHECKS"); do
  echo "--- Check $i ---"
  kubectl get workspace.tf.upbound.io 2>&1
  echo ""

  TOTAL=$(kubectl get workspace.tf.upbound.io --no-headers 2>/dev/null | wc -l | tr -d ' ')
  READY_COUNT=$(kubectl get workspace.tf.upbound.io -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c True || true)

  echo "Ready: $READY_COUNT / $TOTAL"

  if [ "$READY_COUNT" -ge "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo "[wait-tf-workspaces] All $TOTAL workspaces are Ready!"
    exit 0
  fi

  # Show any errors
  for ws in $(kubectl get workspace.tf.upbound.io -o name 2>/dev/null); do
    STATUS=$(kubectl get "$ws" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$STATUS" != "True" ]; then
      REASON=$(kubectl get "$ws" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
      MSG=$(kubectl get "$ws" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null | head -c 200)
      echo "  NOT READY: $ws reason=$REASON msg=$MSG"
    fi
  done

  echo ""
  sleep "$SLEEP_INTERVAL"
done

echo "[wait-tf-workspaces] Timed out waiting for workspaces."
exit 1
