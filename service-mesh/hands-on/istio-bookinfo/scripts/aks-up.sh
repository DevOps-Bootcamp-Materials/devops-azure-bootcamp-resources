#!/usr/bin/env bash
# Bring up a small, throwaway AKS cluster for the W16.2 Istio hands-on.
# Usage: ./aks-up.sh
#
# Two Standard_D2s_v3 nodes is enough for Istio's control plane (istiod + the
# two gateways from the demo profile) plus Bookinfo with sidecars. D-series is
# used instead of B-series because B-series quota is disabled on many IronHack
# subscriptions. Change NODE_VM_SIZE if you have B-series quota.

set -euo pipefail

RG="${RG:-rg-bootcamp-test-istio-bookinfo}"
LOCATION="${LOCATION:-westeurope}"
CLUSTER="${CLUSTER:-aks-istio-demo}"
NODE_COUNT="${NODE_COUNT:-2}"
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