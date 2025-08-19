#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./deploy.sh                # auto-detect env (prefers dev-free, else dev)
#   ./deploy.sh dev-free       # explicit env
#   ./deploy.sh --reset        # reset EC2 app state before deploy
#   ./deploy.sh dev --reset

# -------- helpers --------
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need aws; need jq; need docker; need terraform; need sed

RESET=false
ENV_NAME=""
for a in "$@"; do
  case "$a" in
    --reset) RESET=true ;;
    dev|dev-free|prod-demo) ENV_NAME="$a" ;;
    *) echo "Unknown arg: $a"; exit 1 ;;
  esac
done

# Find repo root (dir containing 'services' and 'infra')
here="$(pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
find_root(){
  d="$1"
  for _ in {1..6}; do
    if [[ -d "$d/services" && -d "$d/infra/terraform/envs" ]]; then
      echo "$d"; return 0
    fi
    d="$(cd "$d/.." && pwd)"
  done
  return 1
}
ROOT="$(find_root "$here" || find_root "$script_dir" || true)"
if [[ -z "$ROOT" ]]; then
  echo "❌ Could not locate repo root (need 'services/' and 'infra/terraform/envs/'). Run from inside the repo."
  exit 1
fi

# Pick env dir
if [[ -z "$ENV_NAME" ]]; then
  if [[ -d "$ROOT/infra/terraform/envs/dev-free" ]]; then
    ENV_NAME="dev-free"
  elif [[ -d "$ROOT/infra/terraform/envs/dev" ]]; then
    ENV_NAME="dev"
  else
    echo "❌ No env folder found (expected infra/terraform/envs/dev-free or dev)."; exit 1
  fi
fi
ENV_DIR="$ROOT/infra/terraform/envs/$ENV_NAME"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
echo "Repo root  : $ROOT"
echo "Env        : $ENV_NAME  ($ENV_DIR)"
echo "Region     : $REGION"

# -------- read terraform outputs --------
echo "Reading Terraform outputs..."
TF_JSON="$(terraform -chdir="$ENV_DIR" output -json)"
EC2_INSTANCE_ID="$(echo "$TF_JSON" | jq -r '.ec2_instance_id.value')"
EC2_PUBLIC_IP="$(echo "$TF_JSON" | jq -r '.ec2_public_ip.value')"
ECR_PAYMENTS="$(echo "$TF_JSON" | jq -r '.ecr_repo_urls.value["payments-api"]')"
ECR_RISK="$(echo "$TF_JSON" | jq -r '.ecr_repo_urls.value["risk-scorer"]')"
if [[ -z "$EC2_INSTANCE_ID" || "$EC2_INSTANCE_ID" == "null" || -z "$EC2_PUBLIC_IP" || "$EC2_PUBLIC_IP" == "null" ]]; then
  echo "❌ Missing ec2 outputs. Did you run 'terraform apply' in $ENV_DIR ?"; exit 1
fi
if [[ -z "$ECR_PAYMENTS" || "$ECR_PAYMENTS" == "null" || -z "$ECR_RISK" || "$ECR_RISK" == "null" ]]; then
  echo "❌ Missing ECR repo outputs. Ensure ECR repos are created in this env."; exit 1
fi
REGISTRY="${ECR_PAYMENTS%%/*}"  # 123456789012.dkr.ecr.us-east-1.amazonaws.com

echo "EC2: $EC2_INSTANCE_ID ($EC2_PUBLIC_IP)"
echo "ECR: $ECR_PAYMENTS"
echo "ECR: $ECR_RISK"

# -------- build & push images locally --------
echo "Logging into ECR locally..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

echo "Building & pushing images..."
docker build -t payments-api:latest "$ROOT/services/payments-api"
docker tag  payments-api:latest "$ECR_PAYMENTS:latest"
docker push "$ECR_PAYMENTS:latest"

docker build -t risk-scorer:latest "$ROOT/services/risk-scorer"
docker tag  risk-scorer:latest "$ECR_RISK:latest"
docker push "$ECR_RISK:latest"

# -------- generate compose (uses both services + observability) --------
COMPOSE_FILE="$(mktemp)"
cat > "$COMPOSE_FILE" <<'YAML'
version: "3.4"
services:
  payments-v1:
    image: __ECR_PAYMENTS__:latest
    ports: ["8080:8080"]
    environment:
      SERVICE_NAME: payments-api
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4318"
  payments-v2:
    image: __ECR_PAYMENTS__:latest
    ports: ["18080:8080"]
    environment:
      SERVICE_NAME: payments-api
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4318"
    deploy:
      replicas: 0
  risk-scorer:
    image: __ECR_RISK__:latest
    ports: ["8081:8081"]
    environment:
      SERVICE_NAME: risk-scorer
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4318"
  otel-collector:
    image: otel/opentelemetry-collector:0.105.0
    command: ["--config=/etc/otel-collector-config.yaml"]
    volumes:
      - /opt/observability/otel-collector-config.yaml:/etc/otel-collector-config.yaml
    network_mode: host
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - /opt/observability/prometheus.yml:/etc/prometheus/prometheus.yml
    ports: ["9090:9090"]
  grafana:
    image: grafana/grafana:latest
    ports: ["3000:3000"]
    volumes:
      - /opt/observability/grafana/provisioning:/etc/grafana/provisioning
YAML
sed -i "s#__ECR_PAYMENTS__#${ECR_PAYMENTS//\//\\/}#g" "$COMPOSE_FILE"
sed -i "s#__ECR_RISK__#${ECR_RISK//\//\\/}#g" "$COMPOSE_FILE"

# -------- read & escape config files --------
esc(){ sed 's/\\/\\\\/g; s/"/\\"/g'; }
OTEL_CFG="$(cat "$ROOT/infra/observability/otel-collector-config.yaml" | esc)"
PROM_CFG="$(cat "$ROOT/infra/observability/prometheus.yml" | esc)"
DS_CFG="$(cat "$ROOT/infra/observability/grafana/provisioning/datasources/datasource.yaml" | esc)"
DASH_JSON="$(cat "$ROOT/infra/observability/grafana/provisioning/dashboards/dashboard.json" | esc)"
NGINX_CONF="$(cat "$ROOT/infra/nginx/nginx.conf" | esc)"
# COMPOSE_ESCAPED="$(cat "$COMPOSE_FILE" | esc)"

# -------- JSON-encode remote commands --------
json_array(){ printf '['; local f=1; for s in "$@"; do s=${s//\\/\\\\}; s=${s//\"/\\\"}; [[ $f -eq 1 ]] && printf '"%s"' "$s" || printf ',"%s"' "$s"; f=0; done; printf ']'; }

CMDS=(
  "set -e"
  "export DEBIAN_FRONTEND=noninteractive"
  "export TERM=linux"

  # Attempt to fix broken packages and clean apt cache before any installs
  "sudo dpkg --configure -a || true" # Try to configure any unconfigured packages
  "sudo apt-get -f install -y || true" # Force resolve missing dependencies
  "sudo apt-get clean" # Clear local repository of retrieved package files
  "sudo rm -rf /var/lib/apt/lists/*" # Clean up apt lists to force fresh update
  "sudo apt-get update -y" # Ensure updated package list before any install

  # Install Docker and Docker Compose
  # "command -v docker >/dev/null 2>&1 || (apt-get update -y && apt-get install -y docker.io docker-compose && systemctl enable docker && systemctl start docker)"
  "command -v docker >/dev/null 2>&1 || (apt-get -o Dpkg::Options::=\"--force-confnew\" install -y docker.io docker-compose && systemctl enable docker && systemctl start docker)"
  # "command -v aws >/dev/null 2>&1 || (apt-get update -y && apt-get install -y awscli)"
  "command -v aws >/dev/null 2>&1 || ( \
    apt-get update -y && apt-get install -y curl unzip && \
    curl \"https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip\" -o \"awscliv2.zip\" && \
    unzip awscliv2.zip && \
    sudo ./aws/install && \
    rm -rf awscliv2.zip aws \
  )"
  "PASS=\$(aws ecr get-login-password --region $REGION) && echo \$PASS | docker login --username AWS --password-stdin $REGISTRY"
)

if $RESET; then
  CMDS+=("docker-compose -f /opt/docker-compose.yml down || true")
  CMDS+=("docker system prune -af || true")
  CMDS+=("rm -rf /opt/observability /etc/nginx /opt/docker-compose.yml || true")
  CMDS+=("mkdir -p /opt/observability /etc/nginx /opt/observability/grafana/provisioning/datasources /opt/observability/grafana/provisioning/dashboards")
else
  CMDS+=("mkdir -p /opt/observability /etc/nginx /opt/observability/grafana/provisioning/datasources /opt/observability/grafana/provisioning/dashboards")
fi

CMDS+=(
  "cat > /opt/docker-compose.yml <<'EOF'"
  # "$COMPOSE_ESCAPED"
  "$(cat "$COMPOSE_FILE")"
  "EOF"
  "cat > /opt/observability/otel-collector-config.yaml <<'EOF'"
  "$OTEL_CFG"
  "EOF"
  "cat > /opt/observability/prometheus.yml <<'EOF'"
  "$PROM_CFG"
  "EOF"
  "cat > /opt/observability/grafana/provisioning/datasources/datasource.yaml <<'EOF'"
  "$DS_CFG"
  "EOF"
  "cat > /opt/observability/grafana/provisioning/dashboards/dashboard.json <<'EOF'"
  "$DASH_JSON"
  "EOF"
  "cat > /etc/nginx/nginx.conf <<'EOF'"
  "$NGINX_CONF"
  "EOF"

  # Install Nginx
  "command -v nginx >/dev/null 2>&1 || (apt-get update -y && apt-get install -y nginx)"
  "docker-compose -f /opt/docker-compose.yml up -d"
  "sudo systemctl stop nginx || true"
  "systemctl enable nginx && systemctl restart nginx"
)

JOINED="$(json_array "${CMDS[@]}")"

echo "Sending commands via SSM to $EC2_INSTANCE_ID ..."
CMD_ID="$(aws ssm send-command \
  --instance-ids "$EC2_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters commands="$JOINED" \
  --region "$REGION" \
  --query 'Command.CommandId' --output text)"

echo "SSM command: $CMD_ID"
echo
echo "✅ Deploy requested. Test:"
echo "  curl http://$EC2_PUBLIC_IP/health"
echo "  curl http://$EC2_PUBLIC_IP/score"
echo "  curl -X POST http://$EC2_PUBLIC_IP/pay -H 'Content-Type: application/json' -d '{\"amount\":12.34,\"currency\":\"USD\",\"user_id\":\"u1\"}'"
echo
echo "Grafana via SSM port-forward:"
echo "  aws ssm start-session --target $EC2_INSTANCE_ID --document-name AWS-StartPortForwardingSession --parameters 'portNumber=3000,localPortNumber=3000' --region $REGION"
