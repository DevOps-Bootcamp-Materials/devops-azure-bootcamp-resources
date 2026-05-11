# =============================================================================
# variables.tf — input parameters for the AKS lab
# =============================================================================
# Variables let us reuse the same Terraform code with different values.
# Set them in a terraform.tfvars file (copy terraform.tfvars.example) or
# pass them on the CLI:  terraform apply -var="subscription_id=xxxx"
# =============================================================================

# Your Azure subscription ID.
# Find it with:  az account show --query id -o tsv
# Required — no default because it is unique to each user.
variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

# Short string prepended to every resource name.
# Keeps names unique if multiple students deploy to the same subscription.
# Example: prefix = "lab05" → resource group "lab05-rg", cluster "lab05-aks"
variable "prefix" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "lab05"
}

# Azure region where all resources are created.
# AKS is available in most regions; pick one close to you for lower latency.
#
# Other options: "eastus", "northeurope", "uksouth", "eastasia"
# Full list:  az account list-locations -o table
variable "location" {
  description = "Azure region where resources will be created"
  type        = string
  default     = "westeurope"
}

# Number of VM nodes in the default node pool.
# Each node runs one or more pods. Kubernetes schedules pods across nodes
# to spread load and improve availability.
#
# For this lab, 1 node is enough — all 3 pods will run on the same VM.
# Increase to 2+ to see how pods spread across different nodes.
# Note: more nodes = more vCPUs consumed against your subscription quota.
variable "node_count" {
  description = "Number of worker nodes in the default node pool"
  type        = number
  default     = 1
}

# Azure VM SKU for each node in the pool.
# This controls the CPU, RAM and local disk available to pods on that node.
#
# Standard_D2s_v3  →  2 vCPU, 8 GB RAM   (recommended for this lab)
# Standard_D4s_v3  →  4 vCPU, 16 GB RAM  (if you need more pod capacity)
# Standard_B2s_v2  →  2 vCPU, 4 GB RAM   (burstable, cheapest option)
#
# Check available SKUs in your region:
#   az vm list-skus --location westeurope --resource-type virtualMachines \
#     --query "[?contains(name,'Standard_D2')].name" -o tsv
variable "vm_size" {
  description = "VM size for AKS worker nodes"
  type        = string
  default     = "Standard_D2s_v3"
}
