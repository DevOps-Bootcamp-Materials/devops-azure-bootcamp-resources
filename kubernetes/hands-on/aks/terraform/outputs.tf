# =============================================================================
# outputs.tf — values exposed after `terraform apply`
# =============================================================================
# Outputs are printed to the terminal once the apply finishes and can be
# read later with:  terraform output <name>
# The deploy.sh script uses these to know which cluster to connect to
# without hardcoding names.
# =============================================================================

# Name of the resource group — used to fetch AKS credentials:
#   az aks get-credentials --resource-group <value> --name <cluster_name>
output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.rg.name
}

# Name of the AKS cluster — used together with resource_group_name
# in az and kubectl commands.
output "cluster_name" {
  description = "Name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.aks.name
}

# Raw kubeconfig YAML that kubectl needs to reach the cluster.
# Marked sensitive so Terraform never prints it in plain text in the logs.
#
# To export it manually to a file:
#   terraform output -raw kube_config > ~/.kube/lab05-config
#   export KUBECONFIG=~/.kube/lab05-config
#
# The deploy.sh script uses `az aks get-credentials` instead, which writes
# the same content directly into ~/.kube/config.
output "kube_config" {
  description = "Raw kubeconfig to connect to the cluster"
  value       = azurerm_kubernetes_cluster.aks.kube_config_raw
  sensitive   = true
}
