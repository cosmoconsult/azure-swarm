resource "azurerm_log_analytics_workspace" "log" {
  name                = "${local.name}-loganalytics"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_log_analytics_datasource_windows_performance_counter" "disk1" {
  name                = "${local.name}-la-disk1"
  resource_group_name = azurerm_resource_group.main.name
  workspace_name      = azurerm_log_analytics_workspace.log.name
  object_name         = "LogicalDisk"
  instance_name       = "*"
  interval_seconds    = 300
  counter_name        = "% Free Space"
}

resource "azurerm_log_analytics_datasource_windows_performance_counter" "disk2" {
  name                = "${local.name}-la-disk2"
  resource_group_name = azurerm_resource_group.main.name
  workspace_name      = azurerm_log_analytics_workspace.log.name
  object_name         = "LogicalDisk"
  instance_name       = "*"
  interval_seconds    = 300
  counter_name        = "Free Megabytes"
}

resource "azurerm_log_analytics_datasource_windows_performance_counter" "mem2" {
  name                = "${local.name}-la-mem2"
  resource_group_name = azurerm_resource_group.main.name
  workspace_name      = azurerm_log_analytics_workspace.log.name
  object_name         = "Memory"
  instance_name       = "*"
  interval_seconds    = 300
  counter_name        = "Available MBytes"
}

resource "azurerm_log_analytics_datasource_windows_performance_counter" "proc1" {
  name                = "${local.name}-la-proc1"
  resource_group_name = azurerm_resource_group.main.name
  workspace_name      = azurerm_log_analytics_workspace.log.name
  object_name         = "Processor"
  instance_name       = "_Total"
  interval_seconds    = 60
  counter_name        = "% Processor Time"
}

resource "azurerm_monitor_action_group" "main" {
  name                = "${local.name}-actiongroup"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "${var.prefix}-act"

  email_receiver {
    name                    = "initial receiver"
    email_address           = var.eMail
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert" "diskBelow25" {
  name                = "${local.name}-diskBelow25"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  action {
    action_group = [
      azurerm_monitor_action_group.main.id
    ]
  }
  data_source_id = azurerm_log_analytics_workspace.log.id
  description    = "Alert when disk free space is below 25%"
  enabled        = true
  query          = <<-QUERY
  Perf
    | where ObjectName == "LogicalDisk" and CounterName == "% Free Space" and InstanceName  != "_Total" and InstanceName  != "D:"
    | where CounterValue <= 25 and CounterValue > 10
    | summarize arg_max(TimeGenerated, *) by Computer, InstanceName
  QUERY
  severity       = 2
  frequency      = 15
  time_window    = 15
  trigger {
    operator  = "GreaterThan"
    threshold = 0
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert" "diskBelow10" {
  name                = "${local.name}-diskBelow10"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  action {
    action_group = [
      azurerm_monitor_action_group.main.id
    ]
  }
  data_source_id = azurerm_log_analytics_workspace.log.id
  description    = "Alert when disk free space is below 10%"
  enabled        = true
  query          = <<-QUERY
  Perf
    | where ObjectName == "LogicalDisk" and CounterName == "% Free Space" and InstanceName  != "_Total" and InstanceName  != "D:"
    | where CounterValue <= 10 and CounterValue > 5
    | summarize arg_max(TimeGenerated, *) by Computer, InstanceName
  QUERY
  severity       = 1
  frequency      = 15
  time_window    = 15
  trigger {
    operator  = "GreaterThan"
    threshold = 0
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert" "diskBelow5" {
  name                = "${local.name}-diskBelow5"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  action {
    action_group = [
      azurerm_monitor_action_group.main.id
    ]
  }
  data_source_id = azurerm_log_analytics_workspace.log.id
  description    = "Alert when disk free space is below 5%"
  enabled        = true
  query          = <<-QUERY
  Perf
    | where ObjectName == "LogicalDisk" and CounterName == "% Free Space" and InstanceName  != "_Total" and InstanceName  != "D:"
    | where CounterValue <= 5
    | summarize arg_max(TimeGenerated, *) by Computer, InstanceName
  QUERY
  severity       = 0
  frequency      = 15
  time_window    = 15
  trigger {
    operator  = "GreaterThan"
    threshold = 0
  }
}
