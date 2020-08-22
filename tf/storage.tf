resource "azurerm_storage_account" "main" {
  name                     = replace("${local.name}-storage", "/[^[:alnum:]]/", "")
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_share" "main" {
  name                 = "share"
  storage_account_name = azurerm_storage_account.main.name
  quota                = 500

  acl {
    id = uuid()

    access_policy {
      permissions = "rwdl"
      start       = timestamp()
      expiry      = timeadd(timestamp(), "87600h")
    }
  }
}
