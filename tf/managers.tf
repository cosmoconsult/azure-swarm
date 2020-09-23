resource "azurerm_subnet" "mgr" {
  name                 = "${local.name}-mgr-sub"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.3.0/24"]
}

resource "azurerm_network_interface" "mgr1" {
  name                = "${local.name}-mgr1-nic"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  ip_configuration {
    name                          = "static-mgr1"
    subnet_id                     = azurerm_subnet.mgr.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.3.4"
  }
}

resource "azurerm_network_interface" "mgr2" {
  count               = var.managerVmSettings.useThree ? 1 : 0
  name                = "${local.name}-mgr2-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "static-mgr2"
    subnet_id                     = azurerm_subnet.mgr.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.3.6"
  }
}

resource "azurerm_network_interface" "mgr3" {
  count               = var.managerVmSettings.useThree ? 1 : 0
  name                = "${local.name}-mgr3-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "static-mgr3"
    subnet_id                     = azurerm_subnet.mgr.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.3.7"
  }
}

resource "azurerm_availability_set" "mgr-avset" {
  name                         = "${local.name}-mgr-avset"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  platform_fault_domain_count  = var.managerVmSettings.useThree ? 3 : 1
  platform_update_domain_count = var.managerVmSettings.useThree ? 3 : 1
  managed                      = true
}

resource "azurerm_network_security_group" "mgr" {
  name                = "${local.name}-mgr-nsg"
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

resource "azurerm_network_interface_security_group_association" "mgr3" {
  count                     = var.managerVmSettings.useThree ? 1 : 0
  network_interface_id      = azurerm_network_interface.mgr3.0.id
  network_security_group_id = azurerm_network_security_group.mgr.id
}

resource "azurerm_network_interface_security_group_association" "mgr2" {
  count                     = var.managerVmSettings.useThree ? 1 : 0
  network_interface_id      = azurerm_network_interface.mgr2.0.id
  network_security_group_id = azurerm_network_security_group.mgr.id
}

resource "azurerm_network_interface_security_group_association" "mgr1" {
  network_interface_id      = azurerm_network_interface.mgr1.id
  network_security_group_id = azurerm_network_security_group.mgr.id
}

resource "azurerm_windows_virtual_machine" "mgr1" {
  name                     = "${local.name}-mgr1-vm"
  computer_name            = "mgr1"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  size                     = var.managerVmSettings.size
  availability_set_id      = azurerm_availability_set.mgr-avset.id
  admin_username           = var.adminUsername
  admin_password           = random_password.password.result
  enable_automatic_updates = false
  network_interface_ids = [
    azurerm_network_interface.mgr1.id,
  ]

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.main.primary_blob_endpoint
  }

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

resource "azurerm_virtual_machine_extension" "initMgr1" {
  name                       = "initMgr1"
  virtual_machine_id         = azurerm_windows_virtual_machine.mgr1.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  depends_on = [
    azurerm_key_vault.main, azurerm_managed_disk.datadisk1
  ]

  settings = jsonencode({
    "fileUris" = [
      "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/${var.branch}/scripts/mgrInitSwarmAndSetupTasks.ps1"
    ]
  })

  protected_settings = jsonencode({
    "commandToExecute" = "powershell -ExecutionPolicy Unrestricted -File mgrInitSwarmAndSetupTasks.ps1 -externaldns \"${local.name}.${var.location}.cloudapp.azure.com\" -email \"${var.eMail}\" -branch \"${var.branch}\" -additionalPreScript \"${var.additionalPreScriptMgr}\" -additionalPostScript \"${var.additionalPostScriptMgr}\" -dockerdatapath \"${var.dockerdatapath}\" -name \"${local.name}\" -storageAccountName \"${azurerm_storage_account.main.name}\" -storageAccountKey \"${azurerm_storage_account.main.primary_access_key}\" -adminPwd \"${random_password.password.result}\" -isFirstmgr -authToken \"${var.authHeaderValue}\" -debugScripts \"${var.debugScripts}\""
  })

}

resource "azurerm_windows_virtual_machine" "mgr2" {
  count                    = var.managerVmSettings.useThree ? 1 : 0
  name                     = "${local.name}-mgr2-vm"
  computer_name            = "mgr2"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  size                     = var.managerVmSettings.size
  availability_set_id      = azurerm_availability_set.mgr-avset.id
  admin_username           = var.adminUsername
  admin_password           = random_password.password.result
  enable_automatic_updates = false
  network_interface_ids = [
    azurerm_network_interface.mgr2.0.id
  ]
  depends_on = [
    azurerm_virtual_machine_extension.initMgr1
  ]

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.main.primary_blob_endpoint
  }

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

resource "azurerm_windows_virtual_machine" "mgr3" {
  count                    = var.managerVmSettings.useThree ? 1 : 0
  name                     = "${local.name}-mgr3-vm"
  computer_name            = "mgr3"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  size                     = var.managerVmSettings.size
  availability_set_id      = azurerm_availability_set.mgr-avset.id
  admin_username           = var.adminUsername
  admin_password           = random_password.password.result
  enable_automatic_updates = false
  network_interface_ids = [
    azurerm_network_interface.mgr3.0.id
  ]
  depends_on = [
    azurerm_virtual_machine_extension.initMgr2
  ]

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.main.primary_blob_endpoint
  }

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

resource "azurerm_virtual_machine_extension" "initMgr2" {
  count                      = var.managerVmSettings.useThree ? 1 : 0
  name                       = "initMgr2"
  virtual_machine_id         = azurerm_windows_virtual_machine.mgr2.0.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  depends_on = [
    azurerm_managed_disk.datadisk2.0
  ]

  settings = jsonencode({
    "fileUris" = [
      "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/${var.branch}/scripts/mgrInitSwarmAndSetupTasks.ps1"
    ]
  })

  protected_settings = jsonencode({
    "commandToExecute" : "powershell -ExecutionPolicy Unrestricted -File mgrInitSwarmAndSetupTasks.ps1 -externaldns \"${local.name}.${var.location}.cloudapp.azure.com\" -email \"${var.eMail}\" -branch \"${var.branch}\" -additionalPreScript \"${var.additionalPreScriptMgr}\" -additionalPostScript \"${var.additionalPostScriptMgr}\" -dockerdatapath \"${var.dockerdatapath}\" -name \"${local.name}\" -storageAccountName \"${azurerm_storage_account.main.name}\" -storageAccountKey \"${azurerm_storage_account.main.primary_access_key}\" -adminPwd \"${random_password.password.result}\" -authToken \"${var.authHeaderValue}\" -debugScripts \"${var.debugScripts}\""
  })

}

resource "azurerm_virtual_machine_extension" "initMgr3" {
  count                      = var.managerVmSettings.useThree ? 1 : 0
  name                       = "initMgr3"
  virtual_machine_id         = azurerm_windows_virtual_machine.mgr3.0.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  depends_on = [
    azurerm_managed_disk.datadisk3.0
  ]

  settings = jsonencode({
    "fileUris" = [
      "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/${var.branch}/scripts/mgrInitSwarmAndSetupTasks.ps1"
    ]
  })

  protected_settings = jsonencode({
    "commandToExecute" : "powershell -ExecutionPolicy Unrestricted -File mgrInitSwarmAndSetupTasks.ps1 -externaldns \"${local.name}.${var.location}.cloudapp.azure.com\" -email \"${var.eMail}\" -branch \"${var.branch}\" -additionalPreScript \"${var.additionalPreScriptMgr}\" -additionalPostScript \"${var.additionalPostScriptMgr}\" -dockerdatapath \"${var.dockerdatapath}\" -name \"${local.name}\" -storageAccountName \"${azurerm_storage_account.main.name}\" -storageAccountKey \"${azurerm_storage_account.main.primary_access_key}\" -adminPwd \"${random_password.password.result}\" -authToken \"${var.authHeaderValue}\" -debugScripts \"${var.debugScripts}\""
  })

}

resource "azurerm_key_vault_access_policy" "mgr1" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_windows_virtual_machine.mgr1.identity.0.principal_id

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

resource "azurerm_key_vault_access_policy" "mgr2" {
  count        = var.managerVmSettings.useThree ? 1 : 0
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_windows_virtual_machine.mgr2.0.identity.0.principal_id

  key_permissions = [
  ]

  secret_permissions = [
    "Get"
  ]

  certificate_permissions = [
  ]
}

resource "azurerm_key_vault_access_policy" "mgr3" {
  count        = var.managerVmSettings.useThree ? 1 : 0
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_windows_virtual_machine.mgr3.0.identity.0.principal_id

  key_permissions = [
  ]

  secret_permissions = [
    "Get"
  ]

  certificate_permissions = [
  ]
}

resource "azurerm_managed_disk" "datadisk1" {
  name                 = "${local.name}-mgr1-datadisk"
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = 4
}

resource "azurerm_virtual_machine_data_disk_attachment" "datadisk1" {
  managed_disk_id    = azurerm_managed_disk.datadisk1.id
  virtual_machine_id = azurerm_windows_virtual_machine.mgr1.id
  lun                = "10"
  caching            = "ReadWrite"
}

resource "azurerm_managed_disk" "datadisk2" {
  count                = var.managerVmSettings.useThree ? 1 : 0
  name                 = "${local.name}-mgr2-datadisk"
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = 4
}

resource "azurerm_virtual_machine_data_disk_attachment" "datadisk2" {
  count              = var.managerVmSettings.useThree ? 1 : 0
  managed_disk_id    = azurerm_managed_disk.datadisk2.0.id
  virtual_machine_id = azurerm_windows_virtual_machine.mgr2.0.id
  lun                = "10"
  caching            = "ReadWrite"
}

resource "azurerm_managed_disk" "datadisk3" {
  count                = var.managerVmSettings.useThree ? 1 : 0
  name                 = "${local.name}-mgr3-datadisk"
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = 4
}

resource "azurerm_virtual_machine_data_disk_attachment" "datadisk3" {
  count              = var.managerVmSettings.useThree ? 1 : 0
  managed_disk_id    = azurerm_managed_disk.datadisk3.0.id
  virtual_machine_id = azurerm_windows_virtual_machine.mgr3.0.id
  lun                = "10"
  caching            = "ReadWrite"
}
