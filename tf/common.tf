provider "azurerm" {
  version = "=2.24.0"
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}
# FIXME: Add state

resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "_%@"
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  min_upper        = 1
}

output "password" {
  value = random_password.password.result
}

resource "azurerm_resource_group" "main" {
  name     = local.name
  location = var.location
}

resource "azurerm_virtual_network" "main" {
  name                = "${local.name}-vnet"
  address_space       = ["10.0.3.0/24", "10.0.4.0/22", "10.0.8.0/23"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

data "azurerm_client_config" "current" {}

resource "random_string" "name" {
  length  = 8
  special = false
  number  = false
  upper   = false
}

output "ssh-to-jumpbox" {
  value = "ssh -l ${var.adminUsername} ${azurerm_public_ip.jumpbox.fqdn}"
}

output "portainer" {
  value = "https://${azurerm_public_ip.main-lb.fqdn}/portainer/"
}

output "ssh-copy-private-key" {
  value = "If you know what you are doing (this is copying your PRIVATE ssh key): ssh -l ${var.adminUsername} ${azurerm_public_ip.jumpbox.fqdn} \"mkdir c:\\users\\${var.adminUsername}\\.ssh\"; scp $HOME\\.ssh\\id_rsa ${var.adminUsername}@${azurerm_public_ip.jumpbox.fqdn}:c:\\users\\${var.adminUsername}\\.ssh"
}

resource "azurerm_key_vault" "main" {
  name                        = "${local.name}-vault"
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
