#!/usr/bin/env bash
# Bring up a small, throwaway AKS cluster for the W15.4 ArgoCD hands-on.
# Usage: ./aks-up.sh
#
# The defaults are intentionally cheap. One Standard_B2s node is enough to host
# Argo CD plus the guestbook example. If you change the names here, change them
# in aks-down.sh too.

set -euo pipefail

RG="${RG:-rg-bootcamp-test-argocd-first-app}"
LOCATION="${LOCATION:-westeurope}"
CLUSTER="${CLUSTER:-aks-argocd-demo}"
NODE_COUNT="${NODE_COUNT:-1}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_D2s_v3}"

echo "[1/3] Creating resource group $RG in $LOCATION"
az group create --name "$RG" --location "$LOCATION" -o none

echo "[2/3] Creating AKS cluster $CLUSTER (count=$NODE_COUNT size=$NODE_VM_SIZE)"
az aks create \
  --resource-group "$RG" \
  --name "$CLUSTER" \
  --node-count "$NODE_COUNT" \
  --node-vm-size "$NODE_VM_SIZE" \
  --enable-managed-identity \
  --generate-ssh-keys \
  -o none

echo "[3/3] Pulling kubeconfig credentials"
az aks get-credentials --resource-group "$RG" --name "$CLUSTER" --overwrite-existing

kubectl get nodes
echo "Done. Tear down with: ./aks-down.sh"