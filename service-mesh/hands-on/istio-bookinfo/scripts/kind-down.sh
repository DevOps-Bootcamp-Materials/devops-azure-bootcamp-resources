#!/usr/bin/env bash
# Tear down the local kind cluster created by kind-up.sh.
# Usage: ./kind-down.sh
#
# Everything (Istio, Bookinfo, all resources) lives inside the kind cluster, so
# deleting the cluster removes all of it at once — no per-resource cleanup needed.

set -euo pipefail

CLUSTER="${CLUSTER:-istio-demo}"

echo "Deleting kind cluster '$CLUSTER'"
kind delete cluster --name "$CLUSTER"
echo "Done."
