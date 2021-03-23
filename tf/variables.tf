variable "prefix" {
  description = "Prefix for all names"
  default     = "swarm"
}

locals {
  name = "${var.prefix}-${random_string.name.result}"
}

variable "location" {
  description = "The Azure Region in which all resources should be created."
  default     = "westeurope"
}

variable "cleanupThresholdGb" {
  description = "The maximum size in GB for docker images on the worker. If exceeded least recently used images are evicted automatically."
  default     = "250"
}

variable "workerVmssSettings" {
  description = "The Azure VM scale set settings for the workers"
  default = {
    size       = "Standard_D8s_v3"
    number     = 2
    sku        = "2019-datacenter-core-with-containers"
    version    = "17763.1158.2004131759"
    diskSizeGb = 1024
  }
}

variable "managerVmSettings" {
  description = "The Azure VM settings for the managers"
  default = {
    size     = "Standard_D2s_v3"
    useThree = true
    sku      = "2019-datacenter-core-with-containers"
    version  = "17763.1158.2004131759"
  }
}

variable "jumpboxVmSettings" {
  description = "The Azure VM settings for the jumpbox"
  default = {
    size    = "Standard_DS1_v2"
    sku     = "2019-datacenter-core"
    version = "latest"
  }
}

variable "adminUsername" {
  description = "The admin username for the VMs"
  default     = "VM-Administrator"
}

variable "branch" {
  description = "The branch of https://github.com/cosmoconsult/azure-swarm to use for downloading files"
  default     = "master"
}

variable "images" {
  description = "Docker images to pull when the workers start"
  default     = ""
}

variable "eMail" {
  description = "eMail address to be used for Let's Encrypt"
  default     = "change@me.com"
}

variable "additionalPreScriptWorker" {
  description = "additional script to call when setting up workers before the main script starts"
  default     = ""
}

variable "additionalPostScriptWorker" {
  description = "additional script to call when setting up workers after the main script starts"
  default     = ""
}

variable "additionalPreScriptMgr" {
  description = "additional script to call when setting up managers before the main script starts"
  default     = ""
}

variable "additionalPostScriptMgr" {
  description = "additional script to call when setting up managers after the main script starts"
  default     = ""
}

variable "additionalPreScriptJumpbox" {
  description = "additional script to call when setting up the jumpbox before the main script starts"
  default     = ""
}

variable "additionalPostScriptJumpbox" {
  description = "additional script to call when setting up the jumpbox after the main script starts"
  default     = ""
}

variable "dockerdatapath" {
  description = "path where the docker data is stored on the workers, relevant it is moved away from the standard path"
  default     = "C:/ProgramData/docker"
}

variable "authHeaderValue" {
  description = "authorization header value to be set when downloading custom scripts, if necessary"
  default     = ""
}

variable "debugScripts" {
  description = "defines whether the called PowerShell scripts show debug output"
  default     = "false"
}

variable "rabbitMqVhost" {
  description = "The virtual host for connecting to RabbitMQ"
  default     = null
}

variable "rabbitMqUserExtension" {
  description = "The username for connecting to RabbitMQ from the VS Code Extension"
  default     = null
}

variable "rabbitMqPasswordExtension" {
  description = "The password for connecting to RabbitMQ from the VS Code Extension"
  default     = null
}

variable "rabbitMqUser" {
  description = "The username for connecting to RabbitMQ"
  default     = null
}

variable "rabbitMqPassword" {
  description = "The password for connecting to RabbitMQ"
  default     = null
}
