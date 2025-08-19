#!/usr/bin/env bash
set -euo pipefail

# Roll back NGINX weights to a safe baseline and optionally stop the canary container.
# Usage:
#   ./rollback.sh            # soft rollback (v1=90%, v2=10%)
#   ./rollback.sh --hard     # hard rollback (also stops payments-v2 container)

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
need aws
need jq
need sed

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
HARD="false"
[[ "${1:-}" == "--hard" ]] && HARD="true"

echo "Region: $REGION"
echo "Mode  : $([[ "$HARD" == "true" ]] && echo "HARD (stop canary)" || echo "SOFT (weights only)")"

# --- Read Terraform outputs ---
TF_JSON="$(terraform output -json)"
EC2_INSTANCE_ID="$(echo "$TF_JSON" | jq -r '.ec2_instance_id.value')"
EC2_PUBLIC_IP="$(echo "$TF_JSON" | jq -r '.ec2_public_ip.value')"
if [[ -z "$EC2_INSTANCE_ID" || "$EC2_INSTANCE_ID" == "null" ]]; then
  echo "❌ Could not read ec2_instance_id from terraform outputs." ; exit 1
fi

# --- Prepare rollback NGINX config from your local template ---
LOCAL_CONF="../../../../infra/nginx/nginx.conf"
if [[ ! -f "$LOCAL_CONF" ]]; then
  echo "❌ Missing $LOCAL_CONF (run from env folder or adjust path)"; exit 1
fi

# Force weights to 9/1 in the upstream block
TMP_CONF="$(mktemp)"
cp "$LOCAL_CONF" "$TMP_CONF"
# Ensure v1 weight=9
sed -i 's#server[[:space:]]\+payments-v1:8080[[:space:]]\+weight=[0-9]\+;#server payments-v1:8080 weight=9;#' "$TMP_CONF" || true
# Ensure v2 weight=1 and uncomment if commented
sed -i 's#^[[:space:]]*# server payments-v2:8080 weight=[0-9]\+;#server payments-v2:8080 weight=1;#' "$TMP_CONF" || true
sed -i 's#^[[:space:]]*#server payments-v2:8080 weight=[0-9]\+;#server payments-v2:8080 weight=1;#' "$TMP_CONF" || true

# Escape for heredoc over SSM
escape() { sed 's/\\/\\\\/g; s/"/\\"/g' "$1"; }
NGINX_ESCAPED="$(escape "$TMP_CONF")"

# --- Build SSM commands array ---
CMDS=()
CMDS+=("cat > /etc/nginx/nginx.conf <<'EOF'")
CMDS+=("$NGINX_ESCAPED")
CMDS+=("EOF")
CMDS+=("nginx -s reload || systemctl restart nginx || true")

if [[ "$HARD" == "true" ]]; then
  # Stop and remove payments-v2 container if it exists
  CMDS+=("docker ps --filter 'name=payments-v2' -q | xargs -r docker stop")
  CMDS+=("docker ps -a --filter 'name=payments-v2' -q | xargs -r docker rm")
fi

# Join commands into JSON array string
JOINED='['
for c in "${CMDS[@]}"; do
  # JSON-escape double quotes
  JOINED+=$(printf '%s' "\"${c//\"/\\\"}\",")
done
JOINED="${JOINED%,}]"

echo "Sending rollback to EC2 via SSM..."
CMD_ID=$(aws ssm send-command \
  --instance-ids "$EC2_INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "TMW rollback: NGINX weights (and optional canary stop)" \
  --parameters commands="$JOINED" \
  --region "$REGION" \
  --query "Command.CommandId" \
  --output text)

echo "SSM command started: $CMD_ID"
echo
echo "✅ Rollback requested."
echo "Test:"
echo "  curl http://${EC2_PUBLIC_IP}/health"
echo "  curl -X POST http://${EC2_PUBLIC_IP}/pay -H 'Content-Type: application/json' -d '{\"amount\":12.34,\"currency\":\"USD\",\"user_id\":\"u1\"}'"
[[ "$HARD" == "true" ]] && echo "Canary container 'payments-v2' was stopped/removed."
