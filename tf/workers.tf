resource "azurerm_virtual_machine_scale_set" "worker" {
  name                = "${local.name}-worker-vmss"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  upgrade_policy_mode = "Manual"
  boot_diagnostics {
    enabled     = true
    storage_uri = azurerm_storage_account.main.primary_blob_endpoint
  }

  sku {
    name     = var.workerVmssSettings.size
    tier     = "Standard"
    capacity = var.workerVmssSettings.number
  }

  os_profile {
    computer_name_prefix = "worker"
    admin_username       = var.adminUsername
    admin_password       = random_password.password.result
  }

  network_profile {
    name    = "worker_profile"
    primary = true

    ip_configuration {
      name      = "internal"
      subnet_id = azurerm_subnet.worker.id
      primary   = true
    }
  }

  storage_profile_os_disk {
    name              = ""
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Premium_LRS"
  }

  storage_profile_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = var.workerVmssSettings.sku
    version   = var.workerVmssSettings.version
  }

  extension {
    name                       = "initWorker"
    publisher                  = "Microsoft.Compute"
    type                       = "CustomScriptExtension"
    type_handler_version       = "1.10"
    auto_upgrade_minor_version = true

    settings = jsonencode({
      "fileUris" = [
        "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/${var.branch}/scripts/workerSetupTasks.ps1"
      ]
    })

    protected_settings = jsonencode({
      "commandToExecute" = "powershell -ExecutionPolicy Unrestricted -File workerSetupTasks.ps1 -images \"${var.images}\" -branch \"${var.branch}\" -additionalPreScript \"${var.additionalPreScriptWorker}\" -additionalPostScript \"${var.additionalPostScriptWorker}\" -name \"${local.name}\" -storageAccountName \"${azurerm_storage_account.main.name}\" -storageAccountKey \"${azurerm_storage_account.main.primary_access_key}\""
    })
  }

  os_profile_windows_config {
    enable_automatic_upgrades = false
    provision_vm_agent        = true
  }

  identity {
    type = "SystemAssigned"
  }

  depends_on = [
    azurerm_virtual_machine_extension.initMgr1
  ]
}

resource "azurerm_subnet" "worker" {
  name                 = "${local.name}-worker-sub"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.4.0/22"]
}

resource "azurerm_key_vault_access_policy" "worker" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_virtual_machine_scale_set.worker.identity.0.principal_id

  key_permissions = [
  ]

  secret_permissions = [
    "Get"
  ]

  certificate_permissions = [
  ]
}
