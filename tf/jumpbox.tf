resource "azurerm_public_ip" "jumpbox" {
 name                         = "${var.name}-jumpbox-publicip"
 location                     = azurerm_resource_group.main.location
 resource_group_name          = azurerm_resource_group.main.name
 allocation_method            = "Static"
 domain_name_label            = "${var.name}-ssh"
}

resource "azurerm_network_interface" "jumpbox" {
 name                = "${var.name}-jumpbox-nic"
 location            = azurerm_resource_group.main.location
 resource_group_name = azurerm_resource_group.main.name

 ip_configuration {
   name                          = "IPConfiguration"
   subnet_id                     = azurerm_subnet.mgr.id
   private_ip_address_allocation = "Static"
   private_ip_address            = "10.0.3.5"
   public_ip_address_id          = azurerm_public_ip.jumpbox.id
 }
}

resource "azurerm_network_security_group" "jumpbox" {
  name                = "${var.name}-jumpbox-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_network_security_rule" "ssh" {
  name                        = "sshIn"
  network_security_group_name = azurerm_network_security_group.jumpbox.name
  resource_group_name         = azurerm_resource_group.main.name
  priority                    = 300
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_network_security_rule" "rdp" {
  name                        = "rdpIn"
  network_security_group_name = azurerm_network_security_group.jumpbox.name
  resource_group_name         = azurerm_resource_group.main.name
  priority                    = 310
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_network_interface_security_group_association" "jumpbox" {
  network_interface_id      = azurerm_network_interface.jumpbox.id
  network_security_group_id = azurerm_network_security_group.jumpbox.id
}

resource "azurerm_windows_virtual_machine" "jumpbox" {
 name                  = "${var.name}-jumpbox-vm"
 computer_name         = "jumpbox"
 location              = azurerm_resource_group.main.location
 resource_group_name   = azurerm_resource_group.main.name
 network_interface_ids = [azurerm_network_interface.jumpbox.id]
 size                  = var.jumpboxVmSettings.size
 admin_username        = var.adminUsername
 admin_password        = random_password.password.result
 
 depends_on            = [ 
  azurerm_key_vault_secret.sshPubKey
 ]

 source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = var.jumpboxVmSettings.sku
    version   = var.jumpboxVmSettings.version
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_virtual_machine_extension" "initJumpBox" {
  name                       = "initJumpBox"
  virtual_machine_id         = azurerm_windows_virtual_machine.jumpbox.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  settings = <<SETTINGS
    {
      "fileUris": [
        "https://raw.githubusercontent.com/cosmoconsult/azure-swarm/${var.branch}/scripts/jumpboxConfig.ps1"
      ]
    }
  SETTINGS

  protected_settings = <<PROTECTED_SETTINGS
    {
      "commandToExecute": "powershell -ExecutionPolicy Unrestricted -File jumpboxConfig.ps1 -branch \"${var.branch}\" -additionalScript \"${var.additionalScriptJumpbox}\" -name \"${var.name}\""
    }
  PROTECTED_SETTINGS

}

resource "azurerm_key_vault_access_policy" "jumpbox" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id = data.azurerm_client_config.current.tenant_id
  object_id = azurerm_windows_virtual_machine.jumpbox.identity.0.principal_id

  key_permissions = [
  ]

  secret_permissions = [
    "Get"
  ]

  certificate_permissions = [
  ]
}