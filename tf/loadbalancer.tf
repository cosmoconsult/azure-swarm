resource "azurerm_public_ip" "main-lb" {
  name                = "${var.name}-lb-publicip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  domain_name_label   = var.name
}

resource "azurerm_lb" "main" {
  name                = "${var.name}-lb"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  frontend_ip_configuration {
    name                 = "publicIPAddress"
    public_ip_address_id = azurerm_public_ip.main-lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "main" {
  resource_group_name = azurerm_resource_group.main.name
  loadbalancer_id     = azurerm_lb.main.id
  name                = "${var.name}-lb-BackEndAddressPool"
}

resource "azurerm_network_interface_backend_address_pool_association" "firstMgr" {
  network_interface_id    = azurerm_network_interface.firstMgr.id
  ip_configuration_name   = "static-firstMgr"
  backend_address_pool_id = azurerm_lb_backend_address_pool.main.id
}

resource "azurerm_network_interface_backend_address_pool_association" "mgr" {
  count                   = var.managerVmSettings.additionalNumber
  network_interface_id    = element(azurerm_network_interface.mgr.*.id, count.index)
  ip_configuration_name   = "dynamic-additional-mgr"
  backend_address_pool_id = azurerm_lb_backend_address_pool.main.id
}

resource "azurerm_lb_probe" "https" {
  resource_group_name = azurerm_resource_group.main.name
  loadbalancer_id     = azurerm_lb.main.id
  name                = "https"
  port                = 443
}

resource "azurerm_lb_rule" "https" {
  resource_group_name            = azurerm_resource_group.main.name
  loadbalancer_id                = azurerm_lb.main.id
  name                           = "https"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "publicIPAddress"
  backend_address_pool_id        = azurerm_lb_backend_address_pool.main.id
  probe_id                       = azurerm_lb_probe.https.id
}
