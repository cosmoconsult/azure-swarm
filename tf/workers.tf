resource "azurerm_windows_virtual_machine_scale_set" "worker" {
  name                 = "${var.name}-worker-vmss"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  sku                  = var.workerVmssSettings.size
  instances            = var.workerVmssSettings.number
  admin_username       = var.adminUsername
  admin_password       = random_password.password.result
  computer_name_prefix = "worker"

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = var.workerVmssSettings.sku
    version   = var.workerVmssSettings.version
  }

  network_interface {
    name    = "worker-nic"
    primary = true

    ip_configuration {
      name      = "dynamic-worker"
      primary   = true
      subnet_id = azurerm_subnet.worker.id
    }
  }

  os_disk {
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_subnet" "worker" {
  name                 = "${var.name}-worker-sub"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.4.0/22"]
}

resource "azurerm_virtual_machine_scale_set_extension" "initWorker" {
  name                         = "example"
  virtual_machine_scale_set_id = azurerm_windows_virtual_machine_scale_set.worker.id
  publisher                    = "Microsoft.Compute"
  type                         = "CustomScriptExtension"
  type_handler_version         = "1.10"
  auto_upgrade_minor_version   = true

  settings = jsonencode({
    "fileUris" = [
      "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/${var.branch}/scripts/workerSetupTasks.ps1"
    ]
  })

  protected_settings = jsonencode({
    "commandToExecute" : "powershell -ExecutionPolicy Unrestricted -File workerSetupTasks.ps1 -images \"${var.images}\" -branch \"${var.branch}\" -additionalScript \"${var.additionalScriptWorker}\" -name \"${var.name}\""
  })
}
