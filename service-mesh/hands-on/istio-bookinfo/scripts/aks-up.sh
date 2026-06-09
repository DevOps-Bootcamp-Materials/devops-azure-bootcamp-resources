#!/usr/bin/env bash
# Bring up a small, throwaway AKS cluster for the W16.2 Istio hands-on, then
# install Istio + Bookinfo on it.
# Usage: ./aks-up.sh
#
# Two Standard_D2s_v3 nodes is enough for Istio's control plane (istiod + the
# two gateways from the demo profile) plus Bookinfo with sidecars. D-series is
# used instead of B-series because B-series quota is disabled on many IronHack
# subscriptions. Change NODE_VM_SIZE if you have B-series quota.
#
# After the cluster is up this hands off to mesh-up.sh (shared with kind-up.sh)
# to install Istio and deploy Bookinfo. The setup is automated on purpose so
# class time goes to inspecting and explaining the mesh, not typing the install.
# Requires istioctl (1.30+) on PATH in addition to az + kubectl.

set -euo pipefail

RG="${RG:-rg-bootcamp-test-istio-bookinfo}"
LOCATION="${LOCATION:-westeurope}"
CLUSTER="${CLUSTER:-aks-istio-demo}"
NODE_COUNT="${NODE_COUNT:-2}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_D2s_v3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

echo "[3/4] Pulling kubeconfig credentials"
az aks get-credentials --resource-group "$RG" --name "$CLUSTER" --overwrite-existing
kubectl get nodes

echo "[4/4] Installing Istio + Bookinfo via mesh-up.sh"
"$SCRIPT_DIR/mesh-up.sh"

echo
echo "Done. Get the public gateway IP with:"
echo "  kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
echo "then open http://<IP>/productpage"
echo
echo "Generate steady traffic for the Kiali demo (separate terminal):  ./scripts/traffic.sh"
echo "Open the Kiali topology graph:                                    istioctl dashboard kiali"
echo
echo "Tear down with: ./aks-down.sh"