#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./destroy.sh [env]
#   ./destroy.sh [env] --dry-run
#   ./destroy.sh [env] --prune-ecr
#   ./destroy.sh [env] --yes --prune-ecr
ENV_NAME="${1:-dev-free}"
shift || true

PRUNE_ECR=false
AUTO=false
DRY=false
for a in "$@"; do
  case "$a" in
    --prune-ecr) PRUNE_ECR=true ;;
    --yes)       AUTO=true ;;
    --dry-run)   DRY=true ;;
    *) echo "Unknown arg: $a"; exit 1 ;;
  esac
done

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need aws; need jq; need terraform

echo "Env   : $ENV_NAME"
echo "Region: $REGION"
echo "Mode  : $([[ "$DRY" == true ]] && echo DRY-RUN || echo LIVE)"
echo "Prune : $([[ "$PRUNE_ECR" == true ]] && echo yes || echo no)"
echo

# Load outputs
TF_JSON="$(terraform -chdir=. output -json || echo '{}')" # <--- CHANGED HERE
ECR_MAP_JSON="$(echo "$TF_JSON" | jq -r '.ecr_repo_urls.value // empty')"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "Terraform state contains:"
terraform -chdir=. state list || true # <--- CHANGED HERE
echo

# Build repo list
REPOS=()
if [[ -n "$ECR_MAP_JSON" ]]; then
  while IFS= read -r uri; do
    REPOS+=("${uri#${REGISTRY}/}")
  done < <(echo "$ECR_MAP_JSON" | jq -r '.[]')
fi

list_imgs(){ aws ecr list-images --repository-name "$1" --region "$REGION" --output json 2>/dev/null | jq -r '.imageIds | length'; }

if [[ "$DRY" == true ]]; then
  echo "🔎 DRY RUN: ECR images that would be deleted (if --prune-ecr)"
  ((${#REPOS[@]})) || echo "   (no repos)"
  for r in "${REPOS[@]}"; do
    echo "   $r : $(list_imgs "$r") images"
  done
  echo
  echo "🔎 DRY RUN: Terraform plan -destroy"
  terraform -chdir=. plan -destroy -var="region=$REGION" || true # <--- CHANGED HERE
  echo
  echo "✅ DRY RUN complete."
  exit 0
fi

if [[ "$AUTO" != true ]]; then
  read -r -p "Proceed destroy in $ENV_NAME ($REGION)? (y/N) " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

if [[ "$PRUNE_ECR" == true && ${#REPOS[@]} -gt 0 ]]; then
  echo "Pruning ECR images..."
  for r in "${REPOS[@]}"; do
    CNT="$(list_imgs "$r")"
    if [[ "$CNT" -gt 0 ]]; then
      echo "   deleting $CNT in $r..."
      aws ecr list-images --repository-name "$r" --region "$REGION" --query 'imageIds[]' --output json \
      | jq -c '.' | while read -r id; do
          aws ecr batch-delete-image --repository-name "$r" --image-ids "[$id]" --region "$REGION" >/dev/null || true
        done
    else
      echo "   (no images) $r"
    fi
  done
  echo "ECR prune complete."
fi

terraform -chdir=. destroy $([[ "$AUTO" == true ]] && echo "-auto-approve") -var="region=$REGION" # <--- CHANGED HERE

echo
echo "✅ Destroy complete."
