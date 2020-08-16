provider "azurerm" {
  version = "=2.23.0"
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}
# FIXME: Add state

resource "random_password" "password" {
  length = 16
  special = true
  override_special = "_%@"
}

output "password" {
  value = random_password.password.result
}

resource "azurerm_resource_group" "main" {
  name     = var.name
  location = var.location
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.name}-vnet"
  address_space       = ["10.0.3.0/24", "10.0.4.0/22", "10.0.8.0/23"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "main" {
  name                        = "${var.name}-vault"
  location                    = azurerm_resource_group.main.location
  resource_group_name         = azurerm_resource_group.main.name
  enabled_for_deployment      = true
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_enabled         = true
  purge_protection_enabled    = false

  sku_name = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    key_permissions = [
      "get",
      "create"
    ]

    secret_permissions = [
      "get",
      "set",
      "list",
      "delete"
    ]

    certificate_permissions = [
      "get",
      "create"
    ]
  }

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}

resource "azurerm_key_vault_secret" "sshPubKey" {
  name         = "sshPubKey"
  value        = file(pathexpand("~/.ssh/id_rsa.pub"))
  key_vault_id = azurerm_key_vault.main.id
}