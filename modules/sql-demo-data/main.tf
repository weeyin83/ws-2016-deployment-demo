############################################
# modules/sql-demo-data
#
# Applies only to VMs using the sql-server-2016-developer image. Runs a
# single CustomScriptExtension that downloads the official Microsoft
# AdventureWorks2016 sample database backup and restores it into the local
# SQL Server instance - see scripts/restore-adventureworks.ps1 for details.
#
# The script is gzip-compressed via a "data external" source (same technique
# used in modules/arc-onboarding) and decompressed by a small PowerShell
# bootstrap in commandToExecute, since Windows CustomScriptExtension always
# runs via "cmd /c", which hard-limits command lines to 8191 characters -
# too small to inline this script (or almost any non-trivial script) directly.
############################################

variable "vm_id" {
  type = string
}

variable "vm_name" {
  description = "VM key/name, e.g. 'native-vm02'. Used only for the extension name/logs."
  type        = string
}

variable "tags" {
  type = map(string)
}

locals {
  restore_script = file("${path.module}/scripts/restore-adventureworks.ps1")
}

data "external" "compressed_script" {
  program = ["bash", "${path.module}/scripts/compress-script.sh"]
  query = {
    script = local.restore_script
  }
}

locals {
  compressed_script_b64 = data.external.compressed_script.result.compressed
}

resource "azurerm_virtual_machine_extension" "sql_demo_data" {
  name                       = "sql-adventureworks-restore"
  virtual_machine_id         = var.vm_id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  tags                       = var.tags

  protected_settings = jsonencode({
    commandToExecute = "powershell -NoProfile -ExecutionPolicy Unrestricted -Command \"$d=[Convert]::FromBase64String('${local.compressed_script_b64}');$ms=New-Object IO.MemoryStream(,$d);$gz=New-Object IO.Compression.GzipStream($ms,[IO.Compression.CompressionMode]::Decompress);$sr=New-Object IO.StreamReader($gz);iex $sr.ReadToEnd()\""
  })

  lifecycle {
    ignore_changes = [tags]
  }
}

output "extension_id" {
  value = azurerm_virtual_machine_extension.sql_demo_data.id
}
