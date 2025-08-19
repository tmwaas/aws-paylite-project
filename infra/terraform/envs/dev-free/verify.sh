#!/usr/bin/env bash
set -euo pipefail

# Usage: ./verify.sh [env]
ENV_NAME="${1:-dev-free}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need aws; need jq; need terraform
command -v nc >/dev/null 2>&1 || true
command -v docker >/dev/null 2>&1 || true

# TF_JSON="$(terraform -chdir=infra/terraform/envs/$ENV_NAME output -json)"
TF_JSON="$(terraform -chdir=. output -json)"

EC2_INSTANCE_ID="$(echo "$TF_JSON" | jq -r '.ec2_instance_id.value')"
EC2_PUBLIC_IP="$(echo "$TF_JSON" | jq -r '.ec2_public_ip.value')"
ECR_MAP="$(echo "$TF_JSON" | jq -r '.ecr_repo_urls.value')"

echo "Region: $REGION"
echo "EC2   : $EC2_INSTANCE_ID ($EC2_PUBLIC_IP)"
echo

echo "Checking EC2 state..."
aws ec2 describe-instances --instance-ids "$EC2_INSTANCE_ID" --region "$REGION" \
  --query 'Reservations[0].Instances[0].{State:State.Name,IP:PublicIpAddress,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table

STATE="$(aws ec2 describe-instances --instance-ids "$EC2_INSTANCE_ID" --region "$REGION" --query 'Reservations[0].Instances[0].State.Name' --output text)"
REAL_IP="$(aws ec2 describe-instances --instance-ids "$EC2_INSTANCE_ID" --region "$REGION" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
[[ "$STATE" == "running" && "$REAL_IP" == "$EC2_PUBLIC_IP" ]] && echo "✅ EC2 running; IP matches." || { echo "❌ EC2 not running or IP mismatch."; exit 1; }

if command -v nc >/dev/null 2>&1; then
  nc -z -w 3 "$EC2_PUBLIC_IP" 22 && echo "✅ Port 22 reachable." || echo "⚠ Port 22 not reachable."
fi

echo
echo "Verifying ECR repos..."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
if [[ "$ECR_MAP" != "null" && -n "$ECR_MAP" ]]; then
  echo "$ECR_MAP" | jq -r '.[]' | while read -r URI; do
    aws ecr describe-repositories --region "$REGION" \
      --query "repositories[?repositoryUri=='$URI'].[repositoryName,repositoryUri]" \
      --output table || true
  done
else
  echo "(no ecr_repo_urls in outputs)"
fi

# Optional: list image tags
if command -v docker >/dev/null 2>&1; then
  echo
  echo "Attempting ECR login to list images..."
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null 2>&1 || true
  echo "$ECR_MAP" | jq -r '.[]' | while read -r URI; do
    REPO="${URI#${REGISTRY}/}"
    echo "Images in $REPO:"
    aws ecr list-images --repository-name "$REPO" --region "$REGION" --query 'imageIds[].imageTag' --output table || true
  done
fi

echo
echo "All checks done."
