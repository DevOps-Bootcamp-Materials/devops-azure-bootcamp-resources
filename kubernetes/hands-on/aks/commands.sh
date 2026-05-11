#!/usr/bin/env bash
# =============================================================================
# Lab 05 — Azure Kubernetes Service (AKS): command walkthrough
# =============================================================================
# Purpose: create a real managed Kubernetes cluster on Azure, deploy a web app,
#          and expose it to the internet using an Azure Load Balancer provisioned
#          automatically by the Kubernetes cloud controller manager.
#
# How to use:
#   Run each block manually. Read the explanation before executing each command.
#
# Prerequisites:
#   az login
#   az account set --subscription "<your-subscription-name-or-id>"
# =============================================================================

# --- Variables — set these once and the rest of the script uses them ----------

RESOURCE_GROUP="rg-aks-lab05"
CLUSTER_NAME="aks-lab05"
LOCATION="westeurope"
NODE_COUNT=2
NODE_SIZE="Standard_B2s"


# =============================================================================
# PART 1 — Create the AKS cluster
# =============================================================================

# 1.1 Create a dedicated resource group for the lab
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION"

# 1.2 Create the AKS cluster.
#   --enable-managed-identity: AKS uses a system-assigned managed identity to
#     call the Azure API (create LBs, disks, etc.) without storing credentials.
#   --generate-ssh-keys: creates an SSH key pair to access node VMs if needed.
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --node-count "$NODE_COUNT" \
  --node-vm-size "$NODE_SIZE" \
  --enable-managed-identity \
  --generate-ssh-keys
# This takes 3–5 minutes. ☕

# 1.3 Merge the cluster credentials into your local kubeconfig.
#   After this command, kubectl talks to your AKS cluster.
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME"

# 1.4 Confirm you are on the right context
kubectl config current-context        # → aks-lab05
kubectl config get-contexts           # list all contexts with their clusters


# =============================================================================
# PART 2 — Inspect the cluster
# =============================================================================

# Node overview — note the EXTERNAL-IP and instance type columns
kubectl get nodes -o wide

# AKS labels nodes with Azure metadata
kubectl get nodes --show-labels | tr ',' '\n' | grep azure

# What is running in the system namespace?
# AKS pre-installs: CoreDNS, kube-proxy, metrics-server, azure-cni-networkmonitor
kubectl get pods -n kube-system

# The control-plane endpoint (AKS hides the master nodes from you)
kubectl cluster-info


# =============================================================================
# PART 3 — Deploy the web application
# =============================================================================

# Create the namespace and switch to it
kubectl apply -f manifests/namespace.yaml
kubectl config set-context --current --namespace=lab05

# Apply all manifests at once:
#   - manifests/configmap-html.yaml  → custom HTML page
#   - manifests/deployment.yaml      → 3 nginx replicas
#   - manifests/service-lb.yaml      → LoadBalancer Service
kubectl apply -f manifests/

# Watch everything come up:
kubectl get all -n lab05

# The Service starts with EXTERNAL-IP = <pending>.
# Azure is provisioning a real Load Balancer in the background (≈ 1 min).
kubectl get service web-lb -n lab05 -w
# Ctrl+C once EXTERNAL-IP shows a real public IP address.


# =============================================================================
# PART 4 — Access from the browser
# =============================================================================

# Capture the public IP assigned to the Service
EXTERNAL_IP=$(kubectl get service web-lb -n lab05 \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "Public IP: $EXTERNAL_IP"
echo "Open in browser: http://$EXTERNAL_IP"

# Quick test from the terminal
curl -s http://$EXTERNAL_IP | head -20


# =============================================================================
# PART 5 — Scale and observe load balancing
# =============================================================================

# Scale up to 5 replicas
kubectl scale deployment ironhack-web --replicas=5

# Pods distribute across both nodes
kubectl get pods -o wide -n lab05

# The Service automatically includes the new Pods in load balancing
# Hit the endpoint 10 times and watch requests spread across Pods:
for i in $(seq 1 10); do
  curl -s "http://$EXTERNAL_IP" | grep -o "ironhack-web-[a-z0-9-]*"
done


# =============================================================================
# PART 6 — Verify what Azure created behind the scenes
# =============================================================================

# AKS creates a second resource group for the infrastructure it manages.
# Its name follows the pattern: MC_<rg>_<cluster>_<location>
MC_RG="MC_${RESOURCE_GROUP}_${CLUSTER_NAME}_${LOCATION}"
echo "Infrastructure resource group: $MC_RG"

# List everything AKS created there (VMs, NICs, disks, IPs, LBs…)
az resource list \
  --resource-group "$MC_RG" \
  --output table

# The public IP that was provisioned for our Service
az network public-ip list \
  --resource-group "$MC_RG" \
  --output table

# Load balancer rules — one per LoadBalancer Service in the cluster
az network lb rule list \
  --resource-group "$MC_RG" \
  --lb-name kubernetes \
  --output table


# =============================================================================
# CLEANUP — always delete resources when done to avoid costs
# =============================================================================

# Remove Kubernetes resources
kubectl delete -f manifests/
kubectl config set-context --current --namespace=default

# Delete the resource group — this also deletes the MC_* group and everything in it
az group delete \
  --name "$RESOURCE_GROUP" \
  --yes \
  --no-wait

echo "Deletion started in the background."
echo "Verify at: https://portal.azure.com"
