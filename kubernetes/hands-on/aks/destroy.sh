#!/usr/bin/env bash
# =============================================================================
# destroy.sh — Lab 05 AKS: tear down all resources created by deploy.sh
# =============================================================================
# Usage:
#   export ARM_SUBSCRIPTION_ID="<your-subscription-id>"
#   chmod +x destroy.sh && ./destroy.sh
#
#   Or pass the subscription ID directly:
#   ./destroy.sh --subscription-id <your-subscription-id>
#
# What this script destroys:
#   1. Kubernetes manifests (deployment, service, configmap, namespace)
#   2. AKS cluster (via Terraform destroy)
#   3. Resource group and everything inside it
#
# Why clean up?
#   AKS nodes are Azure VMs — they incur hourly cost even when idle.
#   Always destroy lab resources when you are done to avoid unexpected charges.
#
# Cost reference (approximate, westeurope, 2025):
#   Standard_D2s_v3 node  ≈ $0.096/hour  (~$70/month if left running)
#   Azure Load Balancer   ≈ $0.025/hour  (~$18/month if left running)
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
    *) die "Unknown argument: $1. Usage: ./destroy.sh [--subscription-id <id>]" ;;
  esac
done

[[ -z "$SUBSCRIPTION_ID" ]] && \
  die "Subscription ID is required.\nSet ARM_SUBSCRIPTION_ID or pass --subscription-id <id>"

# --------------------------------------------------------------------------
# STEP 0 — Prerequisites
# --------------------------------------------------------------------------
log "Checking prerequisites..."
for cmd in terraform kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is not installed or not in PATH."
done
ok "terraform and kubectl present."

# --------------------------------------------------------------------------
# STEP 1 — Remove Kubernetes resources first
# --------------------------------------------------------------------------
# We delete the manifests before running terraform destroy so that
# Kubernetes has a chance to clean up the Azure Load Balancer it provisioned.
# If we destroy the cluster directly, the public IP may remain as an orphaned
# Azure resource in the MC_* infrastructure resource group.
#
# kubectl delete is best-effort here (-f applies in reverse creation order).
# The --ignore-not-found flag prevents errors if the cluster is already gone.
# --------------------------------------------------------------------------
log "Removing Kubernetes manifests (namespace, deployment, service)..."

# Check if kubectl can still reach the cluster before trying to delete
if kubectl cluster-info >/dev/null 2>&1; then
  kubectl delete -f "$MANIFESTS_DIR/" --ignore-not-found
  ok "Kubernetes resources deleted."

  # Switch kubectl back to the default namespace so the context
  # doesn't point at a namespace that no longer exists.
  kubectl config set-context --current --namespace=default 2>/dev/null || true
else
  log "Cluster unreachable — skipping kubectl delete (Terraform will handle it)."
fi

# --------------------------------------------------------------------------
# STEP 2 — Terraform destroy
# --------------------------------------------------------------------------
# `terraform destroy` deletes every resource that Terraform created:
#   - azurerm_kubernetes_cluster.aks  (the AKS cluster + all managed nodes)
#   - azurerm_resource_group.rg       (the resource group and everything in it)
#
# When the resource group is deleted, Azure also automatically deletes the
# MC_* infrastructure resource group that AKS created for node VMs, disks,
# network interfaces, etc.
#
# -auto-approve skips the manual confirmation prompt. Remove this flag if
# you want Terraform to show the destroy plan and ask for confirmation first.
# --------------------------------------------------------------------------
log "Running terraform destroy (~3-5 minutes)..."
terraform -chdir="$TERRAFORM_DIR" destroy \
  -var "subscription_id=$SUBSCRIPTION_ID" \
  -auto-approve

ok "Terraform destroy complete."

# --------------------------------------------------------------------------
# STEP 3 — Remove the kubectl context
# --------------------------------------------------------------------------
# After the cluster is gone, its kubeconfig context is stale.
# We remove it so that future kubectl commands don't accidentally try to
# reach a cluster that no longer exists.
#
# Alternative: keep the context and let kubectl fail — not recommended
# because it can be confusing to debug later.
# --------------------------------------------------------------------------
log "Removing stale kubectl context..."
CLUSTER_CONTEXT="lab05-aks"

if kubectl config get-contexts "$CLUSTER_CONTEXT" >/dev/null 2>&1; then
  kubectl config delete-context "$CLUSTER_CONTEXT"
  ok "kubectl context '$CLUSTER_CONTEXT' removed."
else
  log "Context '$CLUSTER_CONTEXT' not found — nothing to remove."
fi

# --------------------------------------------------------------------------
# Done
# --------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Lab 05 — Cleanup Complete"
echo "============================================================"
echo "  All Azure resources have been deleted."
echo "  No further charges will be incurred for this lab."
echo ""
echo "  Verify in the portal:"
echo "    https://portal.azure.com/#view/HubsExtension/BrowseResourceGroups"
echo "============================================================"
