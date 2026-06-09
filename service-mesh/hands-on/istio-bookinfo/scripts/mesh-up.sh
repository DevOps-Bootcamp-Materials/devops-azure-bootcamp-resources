#!/usr/bin/env bash
# Install Istio (demo profile) + deploy Bookinfo + Gateway/VirtualService +
# DestinationRules + the Prometheus and Kiali observability addons, on whatever
# cluster kubectl currently points at.
# Usage: ./mesh-up.sh
#
# Cluster-agnostic: aks-up.sh and kind-up.sh create the cluster and then call
# this script, so AKS and local kind share exactly the same mesh bring-up.
# This automates the *setup* so class time goes to inspecting and explaining the
# mesh, not typing the install commands. Idempotent: safe to re-run.
#
# Requires on PATH: istioctl (1.30+), kubectl (pointed at the target cluster).

set -euo pipefail

NS="${NS:-bookinfo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$SCRIPT_DIR/../manifests/bookinfo"
ADDONS="$SCRIPT_DIR/../manifests/addons"

for bin in istioctl kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found on PATH"; exit 1; }
done

echo "[1/5] Installing Istio (demo profile)"
istioctl install --set profile=demo -y

echo "[2/5] Creating namespace '$NS' and enabling sidecar injection"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" istio-injection=enabled --overwrite

echo "[3/5] Deploying Bookinfo + Gateway/VirtualService + DestinationRules"
kubectl apply -n "$NS" -f "$MANIFESTS/bookinfo.yaml"
kubectl apply -n "$NS" -f "$MANIFESTS/bookinfo-gateway.yaml"
kubectl apply -n "$NS" -f "$MANIFESTS/destination-rule-all.yaml"

echo "[4/5] Installing observability addons (Prometheus + Kiali)"
kubectl apply -f "$ADDONS/prometheus.yaml"
kubectl apply -f "$ADDONS/kiali.yaml"

echo "[5/5] Waiting for Bookinfo + Kiali to become ready"
kubectl rollout status -n "$NS" deployment/productpage-v1 --timeout=3m
kubectl wait --for=condition=ready pod --all -n "$NS" --timeout=3m
kubectl rollout status -n istio-system deployment/kiali --timeout=3m
kubectl get pods -n "$NS"
