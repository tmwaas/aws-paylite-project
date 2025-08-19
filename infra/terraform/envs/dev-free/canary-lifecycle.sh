#!/usr/bin/env bash
set -euo pipefail

# Usage: ./canary-lifecycle.sh <canary_percent> [test_requests]
# Example: ./canary-lifecycle.sh 30 20

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <canary_percent> [test_requests]"
  exit 1
fi

CANARY_PERCENT="$1"
REQS="${2:-20}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
need bash
need chmod

# Paths
CANARY_SCRIPT="./canary-and-test.sh"
ROLLBACK_SCRIPT="./rollback-canary.sh"

# Ensure scripts are executable
chmod +x "$CANARY_SCRIPT" "$ROLLBACK_SCRIPT"

echo "🚀 Starting Canary Lifecycle Demo..."
echo "Step 1️⃣: Set canary to ${CANARY_PERCENT}% and test"
$CANARY_SCRIPT "$CANARY_PERCENT" "$REQS"

echo
echo "Step 2️⃣: Rollback to 0% v2 (100% v1) and test"
$ROLLBACK_SCRIPT "$REQS"

echo
echo "✅ Canary lifecycle complete!"
