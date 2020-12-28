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

# create shared data disk via ARM template as not supported through azure_managed_disk resource
resource "azurerm_resource_group_template_deployment" "shared_disk" {
  name                = "shared_disk"
  resource_group_name = azurerm_resource_group.main.name
  deployment_mode     = "Incremental"
  template_content    = <<TEMPLATE
{ 
  "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "resources": [
    {
      "type": "Microsoft.Compute/disks",
      "name": "shared_disk",
      "location": "${azurerm_resource_group.main.location}",
      "apiVersion": "2019-07-01",
      "sku": {
        "name": "Premium_LRS"
      },
      "properties": {
        "creationData": {
          "createOption": "Empty"
        },
        "diskSizeGB": "1024",
        "maxShares": "3"
      }
    }
  ] 
}
TEMPLATE
}

# get created shared disk
data "azurerm_managed_disk" "shared_disk" {
  depends_on = [azurerm_resource_group_template_deployment.shared_disk]
  name                = "shared_disk"
  resource_group_name = azurerm_resource_group.main.name
}