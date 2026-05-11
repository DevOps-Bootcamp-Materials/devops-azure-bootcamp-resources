# =============================================================================
# main.tf — AKS cluster definition
# =============================================================================
# This file provisions two Azure resources:
#   1. A Resource Group  →  logical container for everything in this lab
#   2. An AKS cluster    →  the managed Kubernetes control plane + node pool
# =============================================================================

# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------
# All Azure resources must live inside a resource group.
# Deleting the resource group also deletes everything inside it — convenient
# for cleanup after the lab.
#
# Alternative: reuse an existing resource group with a `data` block instead
# of creating a new one:
#
#   data "azurerm_resource_group" "rg" {
#     name = "my-existing-rg"
#   }
#
# Then reference it as: data.azurerm_resource_group.rg.name / .location
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
}

# -----------------------------------------------------------------------------
# AKS Cluster
# -----------------------------------------------------------------------------
# `azurerm_kubernetes_cluster` provisions the full managed cluster:
#   - Azure manages the control plane (API server, etcd, scheduler) at no cost
#   - We only pay for the node VMs in the node pool
# -----------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${var.prefix}-aks"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # dns_prefix is used to build the cluster FQDN:
  #   <dns_prefix>.<region>.azmk8s.io
  # Must be unique within the region.
  dns_prefix = "${var.prefix}-k8s"

  # ---------------------------------------------------------------------------
  # Default node pool — the group of VMs that will run our workloads
  # ---------------------------------------------------------------------------
  # AKS requires exactly one "default" node pool (system pool).
  # Additional node pools (e.g. GPU nodes, spot nodes) can be added with
  # separate `azurerm_kubernetes_cluster_node_pool` resources.
  #
  # node_count: fixed number of nodes.
  # Alternative: enable the cluster autoscaler instead of a fixed count:
  #
  #   default_node_pool {
  #     name                = "default"
  #     vm_size             = var.vm_size
  #     enable_auto_scaling = true
  #     min_count           = 1
  #     max_count           = 3
  #   }
  #
  # vm_size: the Azure VM SKU for each node. The node pool family determines
  # which quota bucket is consumed. Common choices for labs:
  #   Standard_D2s_v3  →  2 vCPU, 8 GB  (general purpose, widely available)
  #   Standard_D4s_v3  →  4 vCPU, 16 GB (more headroom for many pods)
  #   Standard_B2s_v2  →  2 vCPU, 4 GB  (burstable, cheaper but limited)
  # ---------------------------------------------------------------------------
  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = var.vm_size
  }

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------
  # AKS needs an Azure identity to call Azure APIs on our behalf
  # (e.g. provision a Load Balancer when we create a Service of type LB,
  # attach a disk when we create a PersistentVolumeClaim, etc.).
  #
  # type = "SystemAssigned": Azure creates and manages the identity for us
  # automatically. Simplest option and recommended for most use cases.
  #
  # Alternative — use a pre-existing user-assigned managed identity:
  #
  #   identity {
  #     type         = "UserAssigned"
  #     identity_ids = [azurerm_user_assigned_identity.aks.id]
  #   }
  #
  # Or use a Service Principal (older approach, requires manual secret rotation):
  #
  #   service_principal {
  #     client_id     = var.sp_client_id
  #     client_secret = var.sp_client_secret
  #   }
  # ---------------------------------------------------------------------------
  identity {
    type = "SystemAssigned"
  }

  # ---------------------------------------------------------------------------
  # NOT configured here (kept simple for the lab) — notable options:
  #
  # network_profile: choose between kubenet (simple, NAT-based) or azure-cni
  #   (pods get real VNet IPs, required for advanced networking scenarios).
  #
  # oms_agent / monitor_metrics: enable Azure Monitor / Container Insights
  #   for metrics, logs and dashboards in the Azure portal.
  #
  # key_vault_secrets_provider: mount Key Vault secrets directly as volumes
  #   in pods via the Secrets Store CSI driver.
  #
  # sku_tier = "Standard": adds a 99.95 % SLA on the control plane
  #   (default Free tier has no SLA — fine for labs, not for production).
  # ---------------------------------------------------------------------------
}
