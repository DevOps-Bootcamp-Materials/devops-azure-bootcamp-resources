#!/usr/bin/env bash
# Tear down the AKS cluster + resource group from aks-up.sh.
# Usage: ./aks-down.sh
#
# Returns immediately; Azure deletes the resources in the background.
# Run `az group show --name "$RG"` a few minutes later to confirm.

set -euo pipefail

RG="${RG:-rg-bootcamp-test-istio-bookinfo}"

echo "Deleting resource group $RG (async)"
az group delete --name "$RG" --yes --no-wait
echo "Submitted. Verify with: az group show --name $RG"