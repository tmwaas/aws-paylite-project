#!/usr/bin/env bash
set -euo pipefail

# Usage: ./canary.sh <percent>
# Example: ./canary.sh 30   # Sends 30% of traffic to v2, 70% to v1
#          ./canary.sh 100  # Full cutover to v2
#          ./canary.sh 0    # No traffic to v2

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
need aws
need jq
need sed

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <percent>"
  exit 1
fi

PERCENT="$1"
if ! [[ "$PERCENT" =~ ^[0-9]+$ ]] || (( PERCENT < 0 || PERCENT > 100 )); then
  echo "❌ Percent must be between 0 and 100"
  exit 1
fi

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# --- Read Terraform outputs ---
TF_JSON="$(terraform output -json)"
EC2_INSTANCE_ID="$(echo "$TF_JSON" | jq -r '.ec2_instance_id.value')"
EC2_PUBLIC_IP="$(echo "$TF_JSON" | jq -r '.ec2_public_ip.value')"
if [[ -z "$EC2_INSTANCE_ID" || "$EC2_INSTANCE_ID" == "null" ]]; then
  echo "❌ Could not read ec2_instance_id from terraform outputs." ; exit 1
fi

# Convert percent to NGINX weights
# We'll use a scale of 10 so 30% = weight=3, 70% = weight=7
V2_WEIGHT=$(( PERCENT / 10 ))
V1_WEIGHT=$(( 10 - V2_WEIGHT ))

echo "Setting canary to: v1=${V1_WEIGHT}0%  v2=${V2_WEIGHT}0%"
echo "Region: $REGION"
echo "Instance: $EC2_INSTANCE_ID"

# --- Prepare NGINX config ---
LOCAL_CONF="../../../../infra/nginx/nginx.conf"
if [[ ! -f "$LOCAL_CONF" ]]; then
  echo "❌ Missing $LOCAL_CONF (run from env folder or adjust path)"; exit 1
fi

TMP_CONF="$(mktemp)"
cp "$LOCAL_CONF" "$TMP_CONF"
# Update v1 weight
sed -i "s#server[[:space:]]\+payments-v1:8080[[:space:]]\+weight=[0-9]\+;#server payments-v1:8080 weight=${V1_WEIGHT};#" "$TMP_CONF" || true
# Update v2 weight
sed -i "s#server[[:space:]]\+payments-v2:8080[[:space:]]\+weight=[0-9]\+;#server payments-v2:8080 weight=${V2_WEIGHT};#" "$TMP_CONF" || true
# Ensure v2 line is uncommented if weight > 0
if (( V2_WEIGHT > 0 )); then
  sed -i "s/^#\s*server payments-v2:8080/server payments-v2:8080/" "$TMP_CONF"
else
  # Comment out v2 if weight = 0
  sed -i "s/^\s*server payments-v2:8080/# server payments-v2:8080/" "$TMP_CONF"
fi

# Escape config for SSM heredoc
escape() { sed 's/\\/\\\\/g; s/"/\\"/g' "$1"; }
NGINX_ESCAPED="$(escape "$TMP_CONF")"

# --- Send commands via SSM ---
CMDS=()
CMDS+=("cat > /etc/nginx/nginx.conf <<'EOF'")
CMDS+=("$NGINX_ESCAPED")
CMDS+=("EOF")
CMDS+=("nginx -s reload || systemctl restart nginx || true")

JOINED='['
for c in "${CMDS[@]}"; do
  JOINED+=$(printf '%s' "\"${c//\"/\\\"}\",")
done
JOINED="${JOINED%,}]"

CMD_ID=$(aws ssm send-command \
  --instance-ids "$EC2_INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "TMW canary update: ${PERCENT}%" \
  --parameters commands="$JOINED" \
  --region "$REGION" \
  --query "Command.CommandId" \
  --output text)

echo "SSM command started: $CMD_ID"
echo
echo "✅ Canary updated."
echo "Test with:"
echo "  curl http://${EC2_PUBLIC_IP}/pay -H 'Content-Type: application/json' -d '{\"amount\":1.23,\"currency\":\"USD\",\"user_id\":\"u1\"}'"
