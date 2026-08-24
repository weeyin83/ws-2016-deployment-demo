############################################
# modules/arc-onboarding
#
# Applies only to VMs with management_type = "arc-evaluation". Runs a single
# CustomScriptExtension that performs, in strict order, on the VM:
#   1. Arc evaluation prep (MSFT_ARC_TEST env var + persistent Windows
#      Firewall rules blocking IMDS/WireServer)
#   2. Install of the Azure Connected Machine agent
#   3. azcmagent connect (onboarding to Azure Arc)
#   4. Verification (azcmagent show)
#   5. Registration of a deferred, one-time Scheduled Task that stops and
#      disables the Azure Windows VM Guest Agent a few minutes later.
#
# Step 5 MUST be deferred rather than run inline: this whole script executes
# as a child process launched BY the Guest Agent (via the CustomScriptExtension).
# If the script disabled the Guest Agent before the extension had a chance to
# report "Succeeded" back to Azure Resource Manager, the extension resource
# would be stuck in a transitioning state and `terraform apply` would fail
# waiting on it. Deferring via a native Windows Scheduled Task (not a
# Terraform/Azure-side sleep) lets the extension finish and report success
# first, and is the only reliable way to sequence "disable the thing that is
# currently running you" from inside a CustomScriptExtension.
############################################

variable "vm_id" {
  type = string
}

variable "vm_name" {
  description = "VM key/name, e.g. 'arc-vm01'. Must match the computer_name convention used in modules/windows-vm (hyphens stripped)."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subscription_id" {
  type      = string
  sensitive = true
}

variable "tenant_id" {
  type      = string
  sensitive = true
}

variable "service_principal_client_id" {
  type      = string
  sensitive = true
}

variable "service_principal_secret" {
  type      = string
  sensitive = true
}

variable "tags" {
  type = map(string)
}

locals {
  # Must match modules/windows-vm computer_name derivation exactly, since
  # azcmagent registers the Arc machine resource under this exact name.
  arc_machine_name = replace(var.vm_name, "-", "")

  onboarding_script = templatefile("${path.module}/templates/arc-onboarding.ps1.tftpl", {
    resource_group_name = var.resource_group_name
    location            = var.location
    subscription_id     = var.subscription_id
    tenant_id           = var.tenant_id
    sp_client_id        = var.service_principal_client_id
    sp_secret           = var.service_principal_secret
    arc_machine_name    = local.arc_machine_name
  })
}

resource "azurerm_virtual_machine_extension" "arc_onboarding" {
  name                       = "arc-evaluation-onboarding"
  virtual_machine_id         = var.vm_id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  tags                       = var.tags

  # "script" (base64-encoded full script body) is used instead of
  # commandToExecute + fileUris so no script content or secrets are ever
  # written to a publicly reachable storage location - everything is
  # embedded directly in the (sensitive) extension settings.
  protected_settings = jsonencode({
    script = base64encode(local.onboarding_script)
  })

  # Terraform state will contain this rendered script, including the
  # service principal secret, in plaintext unless you use an encrypted /
  # access-controlled remote backend. See README "Terraform state security".
  lifecycle {
    ignore_changes = [tags]
  }
}

# Reads back the Arc-enabled server resource created by azcmagent connect
# once the extension has finished running. Depends explicitly on the
# extension reaching a terminal state so the machine resource is guaranteed
# to already exist in ARM.
data "azurerm_arc_machine" "main" {
  name                = local.arc_machine_name
  resource_group_name = var.resource_group_name

  depends_on = [azurerm_virtual_machine_extension.arc_onboarding]
}

output "arc_machine_resource_id" {
  value = data.azurerm_arc_machine.main.id
}

output "extension_id" {
  value = azurerm_virtual_machine_extension.arc_onboarding.id
}
