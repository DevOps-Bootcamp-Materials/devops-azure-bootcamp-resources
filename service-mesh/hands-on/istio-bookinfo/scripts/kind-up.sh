#!/usr/bin/env bash
# Bring up a local kind cluster with Istio (demo profile) + Bookinfo for the
# W16.2 hands-on. Free, laptop-only alternative to aks-up.sh.
# Usage: ./kind-up.sh
#
# Creates the kind cluster, then hands off to mesh-up.sh (shared with aks-up.sh)
# to install Istio and deploy Bookinfo. Standing the environment up is automated
# so class time goes to inspecting and explaining the mesh, not typing setup.
#
# Requires on PATH: docker (running), kind, istioctl (1.30+), kubectl.
# Idempotent: reuses an existing cluster and re-applies the manifests.

set -euo pipefail

CLUSTER="${CLUSTER:-istio-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for bin in docker kind istioctl kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found on PATH"; exit 1; }
done

echo "[1/2] Creating kind cluster '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "      cluster already exists, reusing it"
else
  kind create cluster --name "$CLUSTER"
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "[2/2] Installing Istio + Bookinfo via mesh-up.sh"
"$SCRIPT_DIR/mesh-up.sh"

cat <<EOF

Done. kind has no cloud LoadBalancer, so the istio-ingressgateway EXTERNAL-IP
stays <pending>. Reach the app through a port-forward instead:

  kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80

then open  http://localhost:8080/productpage  and refresh ~15x to watch the
reviews block rotate between v1 (no stars), v2 (black), v3 (red).

Generate steady traffic for the topology demo (separate terminal):

  ./scripts/traffic.sh

Open the Kiali topology graph:

  istioctl dashboard kiali          # opens a browser to the Kiali graph
  # or: kubectl port-forward -n istio-system svc/kiali 20001:20001
  #     then http://localhost:20001/kiali

Tear everything down with: ./kind-down.sh
EOF
