# BROKEN FILE — used for hands-on 01: AI-assisted debugging
# This file contains intentional errors. Do not fix them before the hands-on.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Error 1: using data source for a resource group that is being created in the same config
data "azurerm_resource_group" "main" {
  name = "rg-myapp-prod"
}

resource "azurerm_resource_group" "main" {
  name     = "rg-myapp-prod"
  location = "West Europe"
}

# Error 2: ACR name contains uppercase — Azure ACR names must be lowercase alphanumeric
resource "azurerm_container_registry" "main" {
  name                = "MyAppACR"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = true    # security concern: admin account should be disabled

  # Error 3: referencing wrong resource (data source instead of resource)
  tags = {
    environment = "production"
    managed_by  = data.azurerm_resource_group.main.name
  }
}

# Error 4: circular dependency — AKS references ACR and ACR references AKS
resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-myapp-prod"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "myapp"

  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "Standard_D2_v2"
  }

  identity {
    type = "SystemAssigned"
  }
}

# Error 5: role assignment uses hardcoded ACR resource ID instead of reference
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-myapp-prod/providers/Microsoft.ContainerRegistry/registries/MyAppACR"
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}
