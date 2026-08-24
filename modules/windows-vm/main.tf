############################################
# modules/windows-vm - single reusable VM implementation
# Used via for_each in root main.tf to create all 5 VMs from one definition.
############################################

variable "vm_key" {
  description = "Unique VM name/key, e.g. 'arc-vm01'."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "admin_username" {
  type = string
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "vm_size" {
  type = string
}

variable "os_disk_storage_account_type" {
  type = string
}

variable "image_reference" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
}

variable "license_type" {
  description = "'None' (default, standard Marketplace licensing) or 'Windows_Server' (Azure Hybrid Benefit)."
  type        = string
}

variable "enable_public_ip" {
  type    = bool
  default = false
}

variable "enable_system_identity" {
  description = "Adds a system-assigned managed identity. Used only by Arc evaluation VMs, to authenticate to the onboarding-script storage account without storage account keys (this subscription enforces shared-key auth to be disabled)."
  type        = bool
  default     = false
}

variable "auto_shutdown_enabled" {
  type = bool
}

variable "auto_shutdown_time" {
  type = string
}

variable "auto_shutdown_timezone" {
  type = string
}

variable "tags" {
  type = map(string)
}

# Public IP is opt-in only, per VM, and never created by default - keeps the
# environment private-by-default and avoids unnecessary attack surface/cost.
resource "azurerm_public_ip" "main" {
  count = var.enable_public_ip ? 1 : 0

  name                = "pip-${var.vm_key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "main" {
  name                = "nic-${var.vm_key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.enable_public_ip ? azurerm_public_ip.main[0].id : null
  }
}

resource "azurerm_windows_virtual_machine" "main" {
  name                = var.vm_key
  computer_name       = replace(var.vm_key, "-", "")
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  license_type        = var.license_type == "None" ? null : var.license_type
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.main.id]

  os_disk {
    name                 = "osdisk-${var.vm_key}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_storage_account_type
  }

  source_image_reference {
    publisher = var.image_reference.publisher
    offer     = var.image_reference.offer
    sku       = var.image_reference.sku
    version   = var.image_reference.version
  }

  # Managed-storage boot diagnostics (no storage_account_uri specified) avoids
  # standing up a dedicated storage account solely for this purpose.
  boot_diagnostics {
    storage_account_uri = null
  }

  dynamic "identity" {
    for_each = var.enable_system_identity ? [1] : []
    content {
      type = "SystemAssigned"
    }
  }
}

# Free, built-in auto-shutdown schedule (Microsoft.DevTestLab/schedules) -
# does NOT require an Azure DevTest Labs instance and adds no additional cost.
# This is the simplest reliable low-cost option; a Logic App/Automation
# Account based schedule would add unnecessary complexity/cost for a demo.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "main" {
  count = var.auto_shutdown_enabled ? 1 : 0

  virtual_machine_id    = azurerm_windows_virtual_machine.main.id
  location              = var.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone

  notification_settings {
    enabled = false
  }

  tags = var.tags
}

output "vm_id" {
  value = azurerm_windows_virtual_machine.main.id
}

output "vm_name" {
  value = azurerm_windows_virtual_machine.main.name
}

output "private_ip_address" {
  value = azurerm_network_interface.main.private_ip_address
}

output "public_ip_address" {
  value = var.enable_public_ip ? azurerm_public_ip.main[0].ip_address : null
}

output "system_identity_principal_id" {
  value = var.enable_system_identity ? azurerm_windows_virtual_machine.main.identity[0].principal_id : null
}
