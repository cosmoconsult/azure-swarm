resource "azurerm_subnet" "mgr" {
  name                 = "${var.name}-mgr-sub"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.3.0/24"]
}

resource "azurerm_network_interface" "firstmgr" {
  name                = "${var.name}-firstmgr-nic"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  ip_configuration {
    name                          = "static-firstmgr"
    subnet_id                     = azurerm_subnet.mgr.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.3.4"
  }
}

resource "azurerm_network_interface" "mgr" {
  count               = var.managerVmSettings.additionalNumber
  name                = "${var.name}-mgr${count.index}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "dynamic-additional-mgr"
    subnet_id                     = azurerm_subnet.mgr.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.3.${count.index + 6}"
  }
}

resource "azurerm_availability_set" "mgr-avset" {
  name                         = "${var.name}-mgr-avset"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  platform_fault_domain_count  = var.managerVmSettings.additionalNumber + 1
  platform_update_domain_count = var.managerVmSettings.additionalNumber + 1
  managed                      = true
}

resource "azurerm_network_security_group" "mgr" {
  name                = "${var.name}-mgr-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_network_security_rule" "https" {
  name                        = "httpsIn"
  network_security_group_name = azurerm_network_security_group.mgr.name
  resource_group_name         = azurerm_resource_group.main.name
  priority                    = 310
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_network_interface_security_group_association" "mgr" {
  count                     = var.managerVmSettings.additionalNumber
  network_interface_id      = element(azurerm_network_interface.mgr.*.id, count.index)
  network_security_group_id = azurerm_network_security_group.mgr.id
}

resource "azurerm_network_interface_security_group_association" "firstmgr" {
  network_interface_id      = azurerm_network_interface.firstmgr.id
  network_security_group_id = azurerm_network_security_group.mgr.id
}

resource "azurerm_windows_virtual_machine" "firstmgr" {
  name                = "${var.name}-firstmgr-vm"
  computer_name       = "firstmgr"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = var.managerVmSettings.size
  availability_set_id = azurerm_availability_set.mgr-avset.id
  admin_username      = var.adminUsername
  admin_password      = random_password.password.result
  network_interface_ids = [
    azurerm_network_interface.firstmgr.id,
  ]

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = var.managerVmSettings.sku
    version   = var.managerVmSettings.version
  }

  os_disk {
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_virtual_machine_extension" "initFirstmgr" {
  name                       = "initFirstmgr"
  virtual_machine_id         = azurerm_windows_virtual_machine.firstmgr.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  depends_on = [
    azurerm_key_vault.main
  ]

  settings = <<SETTINGS
    {
      "fileUris": [
        "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/${var.branch}/scripts/mgrInitSwarmAndSetupTasks.ps1"
      ]
    }
  SETTINGS

  protected_settings = <<PROTECTED_SETTINGS
    {
      "commandToExecute": "powershell -ExecutionPolicy Unrestricted -File mgrInitSwarmAndSetupTasks.ps1 -externaldns \"${var.name}.${var.location}.cloudapp.azure.com\" -email \"${var.eMail}\" -branch \"${var.branch}\" -additionalScript \"${var.additionalScriptJumpbox}\" -name \"${var.name}\" -isFirstmgr"
    }
  PROTECTED_SETTINGS

}

resource "azurerm_windows_virtual_machine" "mgr" {
  count               = var.managerVmSettings.additionalNumber
  name                = "${var.name}-mgr${count.index}-vm"
  computer_name       = "mgr${count.index}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = var.managerVmSettings.size
  availability_set_id = azurerm_availability_set.mgr-avset.id
  admin_username      = var.adminUsername
  admin_password      = random_password.password.result
  network_interface_ids = [
    element(azurerm_network_interface.mgr.*.id, count.index)
  ]

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = var.managerVmSettings.sku
    version   = var.managerVmSettings.version
  }

  os_disk {
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_virtual_machine_extension" "initMgr" {
  count                      = var.managerVmSettings.additionalNumber
  name                       = "initMgr"
  virtual_machine_id         = element(azurerm_windows_virtual_machine.mgr.*.id, count.index)
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  depends_on = [
    azurerm_virtual_machine_extension.initFirstmgr
  ]

  settings = <<SETTINGS
    {
      "fileUris": [
        "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/${var.branch}/scripts/mgrInitSwarmAndSetupTasks.ps1"
      ]
    }
  SETTINGS

  protected_settings = <<PROTECTED_SETTINGS
    {
      "commandToExecute": "powershell -ExecutionPolicy Unrestricted -File mgrInitSwarmAndSetupTasks.ps1 -externaldns \"${var.name}.${var.location}.cloudapp.azure.com\" -email \"${var.eMail}\" -branch \"${var.branch}\" -additionalScript \"${var.additionalScriptJumpbox}\" -name \"${var.name}\""
    }
  PROTECTED_SETTINGS

}

resource "azurerm_key_vault_access_policy" "firstMgr" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_windows_virtual_machine.firstMgr.identity.0.principal_id

  key_permissions = [
  ]

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete"
  ]

  certificate_permissions = [
  ]
}

resource "azurerm_key_vault_access_policy" "mgr" {
  count        = var.managerVmSettings.additionalNumber
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = element(azurerm_windows_virtual_machine.mgr.*.identity.0.principal_id, count.index)

  key_permissions = [
  ]

  secret_permissions = [
    "Get"
  ]

  certificate_permissions = [
  ]
}
