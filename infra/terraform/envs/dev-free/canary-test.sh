#!/usr/bin/env bash
set -euo pipefail

# Usage: ./canary-test.sh [num_requests]
# Example: ./canary-test.sh 50

REQS="${1:-20}"  # Default = 20 requests
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
need terraform
need jq
need curl

# --- Get EC2 public IP from Terraform ---
EC2_PUBLIC_IP="$(terraform output -raw ec2_public_ip 2>/dev/null || true)"
if [[ -z "$EC2_PUBLIC_IP" ]]; then
  echo "❌ Could not read ec2_public_ip from terraform outputs."
  exit 1
fi

echo "Testing canary traffic split with $REQS requests..."
echo "Target: http://${EC2_PUBLIC_IP}/pay"
echo

V1_COUNT=0
V2_COUNT=0

for i in $(seq 1 "$REQS"); do
  RESP=$(curl -s -X POST "http://${EC2_PUBLIC_IP}/pay" \
    -H "Content-Type: application/json" \
    -d '{"amount":1.23,"currency":"USD","user_id":"u1"}')

  if [[ "$RESP" == *"v1"* ]]; then
    ((V1_COUNT++))
  elif [[ "$RESP" == *"v2"* ]]; then
    ((V2_COUNT++))
  fi
done

echo "Results:"
echo "  v1 responses: $V1_COUNT"
echo "  v2 responses: $V2_COUNT"

V1_PERCENT=$(( 100 * V1_COUNT / REQS ))
V2_PERCENT=$(( 100 * V2_COUNT / REQS ))

echo
echo "Traffic split observed:"
echo "  v1: ${V1_PERCENT}%"
echo "  v2: ${V2_PERCENT}%"
echo "✅ Test complete."
