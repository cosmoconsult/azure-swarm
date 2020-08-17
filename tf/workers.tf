resource "azurerm_windows_virtual_machine_scale_set" "workers" {
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
