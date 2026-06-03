#!/usr/bin/env bash
#
# Idempotent provisioning for the W15.2 hands-on:
#   - Resource Group
#   - Azure Monitor Workspace (managed Prometheus)
#   - Azure Managed Grafana (Standard SKU)
#   - Grafana -> Workspace integration (managed-identity auth + data source)
#   - AKS cluster with the Azure Monitor metrics add-on enabled
#   - (optional) Container Insights / logs, only when ENABLE_LOGS=1
#
# Run with:        bash provision.sh
# Run with logs:   ENABLE_LOGS=1 bash provision.sh
# Tear down:       az group delete --name "$RG" --yes --no-wait
#   NOTE: if you enabled logs, the default Log Analytics workspace is created in
#   DefaultResourceGroup-<region> (OUTSIDE "$RG") and survives that delete —
#   remove it separately (see the README "Cleanup" section).
#
set -euo pipefail

# Prevent Git Bash / MSYS on Windows from rewriting Azure resource IDs
# (which start with '/subscriptions/...') into Windows paths.
export MSYS_NO_PATHCONV=1

LOCATION="${LOCATION:-westeurope}"
RG="${RG:-rg-bootcamp-test-azmon-prom-grafana}"
AMW="${AMW:-amw-bootcamp}"
GRAFANA="${GRAFANA:-amg-bootcamp}"
AKS="${AKS:-aks-bootcamp-azmon}"
ENABLE_LOGS="${ENABLE_LOGS:-0}"   # set to 1 to also enable Container Insights (logs)

echo "==> Using subscription: $(az account show --query name -o tsv)"
echo "==> Region: $LOCATION  RG: $RG"

echo "==> Ensuring Azure CLI extensions are present"
az extension show --name amg >/dev/null 2>&1 || az extension add --name amg --yes

echo "==> Resource group"
az group create --name "$RG" --location "$LOCATION" >/dev/null

echo "==> Azure Monitor Workspace (managed Prometheus)"
if ! az monitor account show --name "$AMW" --resource-group "$RG" >/dev/null 2>&1; then
  az monitor account create \
    --name "$AMW" \
    --resource-group "$RG" \
    --location "$LOCATION" >/dev/null
fi
AMW_ID=$(az monitor account show --name "$AMW" --resource-group "$RG" --query id -o tsv)
echo "    id: $AMW_ID"

echo "==> Azure Managed Grafana (Standard SKU; required by the AMW integration)"
if ! az grafana show --name "$GRAFANA" --resource-group "$RG" >/dev/null 2>&1; then
  az grafana create \
    --name "$GRAFANA" \
    --resource-group "$RG" \
    --location "$LOCATION" \
    --sku Standard >/dev/null
fi
# Wait until any in-flight provisioning settles before mutating it again.
while [[ "$(az grafana show --name "$GRAFANA" --resource-group "$RG" --query properties.provisioningState -o tsv)" != "Succeeded" ]]; do
  echo "    waiting for Grafana provisioningState=Succeeded..."
  sleep 15
done

echo "==> Linking Workspace as a Grafana data source"
az grafana integrations monitor add \
  --name "$GRAFANA" \
  --resource-group "$RG" \
  --monitor-name "$AMW" \
  --monitor-resource-group-name "$RG" >/dev/null 2>&1 || \
  echo "    (already linked — skipping)"

echo "==> AKS cluster with metrics add-on"
if ! az aks show --resource-group "$RG" --name "$AKS" >/dev/null 2>&1; then
  az aks create \
    --resource-group "$RG" \
    --name "$AKS" \
    --location "$LOCATION" \
    --node-count 2 \
    --node-vm-size Standard_D2als_v7 \
    --enable-managed-identity \
    --enable-azure-monitor-metrics \
    --azure-monitor-workspace-resource-id "$AMW_ID" \
    --generate-ssh-keys >/dev/null
fi

az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing

if [[ "$ENABLE_LOGS" == "1" ]]; then
  echo "==> Container Insights / logs (ENABLE_LOGS=1)"
  if [[ "$(az aks show --resource-group "$RG" --name "$AKS" --query 'addonProfiles.omsagent.enabled' -o tsv 2>/dev/null)" != "true" ]]; then
    az aks enable-addons --addon monitoring --resource-group "$RG" --name "$AKS" >/dev/null
  fi
  LA_WS_ID=$(az aks show --resource-group "$RG" --name "$AKS" \
    --query 'addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID' -o tsv)
  echo "    Log Analytics workspace: $LA_WS_ID"
  echo "    (NOTE: lives in DefaultResourceGroup-<region>, OUTSIDE $RG — delete separately)"
fi

echo
echo "==> Done."
echo "    Workspace query endpoint: $(az monitor account show --name "$AMW" --resource-group "$RG" --query metrics.prometheusQueryEndpoint -o tsv)"
echo "    Grafana endpoint:         $(az grafana show --name "$GRAFANA" --resource-group "$RG" --query properties.endpoint -o tsv)"
if [[ "$ENABLE_LOGS" == "1" ]]; then
  echo "    Logs: deploy a log source with 'kubectl apply -f manifests/logs/' and query ContainerLogV2 (KQL)."
fi
