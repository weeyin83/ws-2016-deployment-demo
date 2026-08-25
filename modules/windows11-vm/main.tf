############################################
# modules/windows11-vm - Windows 11 admin workstation
# Single-purpose VM used to RDP in from a remote laptop and manage the
# Windows Server VMs already deployed in the shared VNet/subnet. Pre-installs
# Azure CLI, Power BI Desktop, and SQL Server Management Studio via Chocolatey.
############################################

variable "vm_key" {
  description = "Unique VM name/key, e.g. 'win11-workstation'."
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
  description = "'None' (standard Marketplace licensing) or 'Windows_Client' (Azure Hybrid Benefit for Windows client OS - only set this if you hold qualifying Windows/Microsoft 365 multi-tenant hosting rights)."
  type        = string
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

# Always public - the whole purpose of this VM is inbound RDP from a remote
# laptop. Access is still locked down to a single trusted CIDR at the NSG
# (see root main.tf / modules/network), never left open to the internet.
resource "azurerm_public_ip" "main" {
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
    public_ip_address_id          = azurerm_public_ip.main.id
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

  # The win11-*-pro/-ent Marketplace images are Gen2 and require Trusted
  # Launch (Secure Boot + vTPM) - Windows 11 itself requires a vTPM, so this
  # is not optional for this image family. This azurerm provider models
  # Trusted Launch purely via these two booleans (no separate security_type
  # argument on this resource).
  secure_boot_enabled = true
  vtpm_enabled        = true

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

  boot_diagnostics {
    storage_account_uri = null
  }
}

# Chocolatey-based install of the requested admin tooling. Runs as SYSTEM via
# the extension, so no interactive winget/App Installer session is needed.
# Script is small (~2.3KB base64-encoded) - well under the 8191-char cmd.exe
# commandToExecute limit, so no gzip/storage-account staging is needed here.
resource "azurerm_virtual_machine_extension" "install_admin_tools" {
  name                       = "install-admin-tools"
  virtual_machine_id         = azurerm_windows_virtual_machine.main.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    commandToExecute = "powershell -NoProfile -ExecutionPolicy Unrestricted -EncodedCommand ${textencodebase64(file("${path.module}/scripts/install-admin-tools.ps1"), "UTF-16LE")}"
  })

  tags = var.tags
}

# Same free, built-in auto-shutdown schedule used for the other VMs.
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
  value = azurerm_public_ip.main.ip_address
}
