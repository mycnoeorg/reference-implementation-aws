#!/usr/bin/env bash
# Purpose: Stop all port-forward sessions started by start-port-forwards.sh
# Usage: ./scripts/stop-port-forwards.sh
set -euo pipefail

PID_FILE="/tmp/cnoe-pf-pids.txt"

echo "[port-forward] Stopping port-forward sessions..."

if [ ! -f "$PID_FILE" ]; then
  echo "[port-forward] No PID file found. Nothing to stop."
  exit 0
fi

while read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    echo "  Stopped PID $pid"
  else
    echo "  PID $pid already stopped"
  fi
done < "$PID_FILE"

rm -f "$PID_FILE"
echo "[port-forward] Done."
