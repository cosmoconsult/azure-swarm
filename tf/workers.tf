resource "azurerm_windows_virtual_machine_scale_set" "worker" {
  name                = "${local.name}-worker-vmss"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  upgrade_mode = "Automatic"  # TODO is this a prob?

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.main.primary_blob_endpoint
  }

  sku                 = var.workerVmssSettings.size
  instances           = var.workerVmssSettings.number

  computer_name_prefix = "worker"
  admin_password      = random_password.password.result
  admin_username      = var.adminUsername

  network_interface {
    name    = "worker_profile"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.worker.id
    }
  }

  os_disk {
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
  }

  data_disk {
    lun               = 10
    caching           = "ReadWrite"
    create_option     = "Empty"
    disk_size_gb      = var.workerVmssSettings.diskSizeGb
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = var.workerVmssSettings.sku
    version   = var.workerVmssSettings.version
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
  object_id    = azurerm_windows_virtual_machine_scale_set.worker.identity.0.principal_id

  key_permissions = [
  ]

  secret_permissions = [
    "Get"
  ]

  certificate_permissions = [
  ]
}

# existing data disks can't be attached to VMSSs but instead must be attached to the instances, this doesn't work with azurerm_virtual_machine_data_disk_attachment but only via azure CLI for now
# azure CLI should normally be available as you need to signin to azure via CLI
resource "null_resource" "attach_shared_disk" {
  depends_on = [azurerm_resource_group_template_deployment.shared_disk]

  provisioner "local-exec" {
    interpreter = [
        "powershell.exe",
        "-Command"
    ]
    command = <<EOF
$instanceIdsString = az vmss list-instances -g ${azurerm_resource_group.main.name} -n ${azurerm_windows_virtual_machine_scale_set.worker.name} --query [].instanceId
$instanceIds = ConvertFrom-Json $([string]::Join(" ", $instanceIdsString))

foreach ($instanceId in $instanceIds) { 
    az vmss disk attach --caching none --disk ${data.azurerm_managed_disk.shared_disk.name} --lun 0 --vmss-name ${azurerm_windows_virtual_machine_scale_set.worker.name} --resource-group ${azurerm_resource_group.main.name} --instance-id $instanceId
}
EOF
  }
}

resource "azurerm_virtual_machine_scale_set_extension" "initWorker" {
  depends_on = [null_resource.attach_shared_disk]
  virtual_machine_scale_set_id = azurerm_windows_virtual_machine_scale_set.worker.id
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
    "commandToExecute" = "powershell -ExecutionPolicy Unrestricted -File workerSetupTasks.ps1 -images \"${var.images}\" -branch \"${var.branch}\" -additionalPreScript \"${var.additionalPreScriptWorker}\" -additionalPostScript \"${var.additionalPostScriptWorker}\" -name \"${local.name}\" -storageAccountName \"${azurerm_storage_account.main.name}\" -storageAccountKey \"${azurerm_storage_account.main.primary_access_key}\" -authToken \"${var.authHeaderValue}\" -debugScripts \"${var.debugScripts}\" -user \"${var.adminUsername}\" -password \"${random_password.password.result}\""
  })
}