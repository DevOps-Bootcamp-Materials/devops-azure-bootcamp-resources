#!/usr/bin/env bash
# Tear down the AKS cluster created by aks-up.sh.
# Uses --no-wait so the script returns immediately; Azure deletes in the
# background. Verify with: az group show --name $RG (eventually NotFound).

set -euo pipefail

RG="${RG:-rg-bootcamp-test-argocd-first-app}"

echo "Deleting resource group $RG (async, --no-wait)"
az group delete --name "$RG" --yes --no-wait

echo "Deletion submitted. Run this to confirm it eventually finishes:"
echo "  az group show --name $RG"