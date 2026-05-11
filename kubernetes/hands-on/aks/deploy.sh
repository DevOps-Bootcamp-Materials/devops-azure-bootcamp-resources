#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Lab 05 AKS: provision cluster + deploy app + verify access
# =============================================================================
# Usage:
#   export ARM_SUBSCRIPTION_ID="<your-subscription-id>"
#   chmod +x deploy.sh && ./deploy.sh
#
#   Or pass the subscription ID directly:
#   ./deploy.sh --subscription-id <your-subscription-id>
#
# What this script does:
#   1. Runs Terraform to create the AKS cluster (resource group + cluster)
#   2. Configures kubectl to point at the new cluster
#   3. Applies all Kubernetes manifests (namespace, configmap, deployment, service)
#   4. Waits for the Azure Load Balancer to assign a public IP
#   5. Runs a curl check and prints the cluster + pod summary
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
log() { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
ok()  { echo -e "\033[1;32m[OK]\033[0m    $*"; }
err() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
die() { err "$*"; exit 1; }

# --------------------------------------------------------------------------
# Parse arguments
# --------------------------------------------------------------------------
SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
    *) die "Unknown argument: $1. Usage: ./deploy.sh [--subscription-id <id>]" ;;
  esac
done

[[ -z "$SUBSCRIPTION_ID" ]] && \
  die "Subscription ID is required.\nSet ARM_SUBSCRIPTION_ID or pass --subscription-id <id>"

# --------------------------------------------------------------------------
# STEP 0 — Prerequisites
# --------------------------------------------------------------------------
log "Checking prerequisites..."
for cmd in terraform az kubectl curl; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is not installed or not in PATH."
done
ok "terraform, az, kubectl, curl — all present."

# --------------------------------------------------------------------------
# STEP 1 — Terraform: provision AKS
# --------------------------------------------------------------------------
log "Initializing Terraform..."
terraform -chdir="$TERRAFORM_DIR" init -upgrade

log "Applying Terraform — this creates the AKS cluster (~5 minutes)..."
terraform -chdir="$TERRAFORM_DIR" apply \
  -var "subscription_id=$SUBSCRIPTION_ID" \
  -auto-approve

RESOURCE_GROUP=$(terraform -chdir="$TERRAFORM_DIR" output -raw resource_group_name)
CLUSTER_NAME=$(terraform -chdir="$TERRAFORM_DIR" output -raw cluster_name)
ok "Cluster '$CLUSTER_NAME' ready in resource group '$RESOURCE_GROUP'."

# --------------------------------------------------------------------------
# STEP 2 — Configure kubectl
# --------------------------------------------------------------------------
log "Fetching AKS credentials and updating kubeconfig..."
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing

ok "kubectl context → $(kubectl config current-context)"

log "Cluster nodes:"
kubectl get nodes -o wide

# --------------------------------------------------------------------------
# STEP 3 — Apply Kubernetes manifests
# --------------------------------------------------------------------------
log "Applying namespace..."
kubectl apply -f "$MANIFESTS_DIR/namespace.yaml"

log "Applying deployment, configmap and service manifests..."
kubectl apply -f "$MANIFESTS_DIR/"

ok "All manifests applied."
kubectl get all -n lab05

# --------------------------------------------------------------------------
# STEP 4 — Wait for LoadBalancer external IP
# --------------------------------------------------------------------------
log "Waiting for the Azure Load Balancer to assign an external IP (~1-2 minutes)..."
EXTERNAL_IP=""
TIMEOUT=180
ELAPSED=0

until [[ -n "$EXTERNAL_IP" && "$EXTERNAL_IP" != "null" ]]; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    die "Timed out after ${TIMEOUT}s waiting for an external IP. Check: kubectl get service web-lb -n lab05"
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
  EXTERNAL_IP=$(kubectl get service web-lb -n lab05 \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  [[ -z "$EXTERNAL_IP" ]] && log "  ...waiting (${ELAPSED}s elapsed)"
done

ok "External IP assigned: $EXTERNAL_IP"

# --------------------------------------------------------------------------
# STEP 5 — Verify HTTP access through the Load Balancer
# --------------------------------------------------------------------------
log "Waiting a few seconds for the load balancer to be fully ready..."
sleep 10

log "Testing HTTP access to http://$EXTERNAL_IP ..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 15 --max-time 30 \
  "http://$EXTERNAL_IP" || echo "000")

if [[ "$HTTP_STATUS" == "200" ]]; then
  ok "HTTP 200 received — the web app is reachable!"
else
  err "Got HTTP status '$HTTP_STATUS'. The service may still be starting. Try: curl http://$EXTERNAL_IP"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Lab 05 — Deployment Complete"
echo "============================================================"
echo "  Resource Group  : $RESOURCE_GROUP"
echo "  AKS Cluster     : $CLUSTER_NAME"
echo "  External IP     : $EXTERNAL_IP"
echo "  App URL         : http://$EXTERNAL_IP"
echo ""
echo "  Quick tests:"
echo "    curl http://$EXTERNAL_IP"
echo "    curl http://$EXTERNAL_IP/hostname"
echo ""
echo "  Cluster nodes:"
kubectl get nodes -o wide
echo ""
echo "  Pods in lab05 namespace:"
kubectl get pods -n lab05 -o wide
echo "============================================================"
echo ""
echo "  Cleanup when done:"
echo "    terraform -chdir=terraform destroy -var subscription_id=\$ARM_SUBSCRIPTION_ID -auto-approve"
echo "============================================================"
