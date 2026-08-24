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
#
# When interactive_mode = true, steps 3-5 are skipped entirely: azcmagent
# connect requires an interactive device-code/browser login that cannot run
# unattended inside a CustomScriptExtension. Only steps 1-2 run automatically;
# a human must then RDP/Serial-Console in and run
# scripts/Complete-InteractiveArcOnboarding.ps1 to finish onboarding.
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
  description = "Empty when interactive_mode = true (no service principal is used)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "service_principal_secret" {
  description = "Empty when interactive_mode = true (no service principal is used)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "interactive_mode" {
  description = "If true, the extension only preps the VM and installs the Connected Machine agent - it does NOT run azcmagent connect (which requires an interactive device-code login). Use scripts/Complete-InteractiveArcOnboarding.ps1 manually afterwards."
  type        = bool
  default     = false
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
    interactive_mode    = tostring(var.interactive_mode)
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

  # Windows CustomScriptExtension requires "commandToExecute" (unlike the
  # Linux variant, it has no standalone "script" property). The script body
  # is passed inline via PowerShell's -EncodedCommand (base64 of UTF-16LE
  # text) so no script content or secrets are ever written to a publicly
  # reachable storage location - everything stays in the (sensitive)
  # protected_settings, never in the public settings or command-line logs.
  protected_settings = jsonencode({
    commandToExecute = "powershell -NoProfile -ExecutionPolicy Unrestricted -EncodedCommand ${textencodebase64(local.onboarding_script, "UTF-16LE")}"
  })

  # Terraform state will contain this rendered script, including the
  # service principal secret, in plaintext unless you use an encrypted /
  # access-controlled remote backend. See README "Terraform state security".
  lifecycle {
    ignore_changes = [tags]
  }
}

# Reads back the Arc-enabled server resource created by azcmagent connect once
# the extension has finished running. Skipped in interactive_mode, since the
# machine resource doesn't exist yet - the human still has to complete the
# connect step themselves (see scripts/Complete-InteractiveArcOnboarding.ps1).
data "azurerm_arc_machine" "main" {
  count = var.interactive_mode ? 0 : 1

  name                = local.arc_machine_name
  resource_group_name = var.resource_group_name

  depends_on = [azurerm_virtual_machine_extension.arc_onboarding]
}

output "arc_machine_resource_id" {
  value = var.interactive_mode ? "not-yet-connected: run scripts/Complete-InteractiveArcOnboarding.ps1 on ${var.vm_name}" : data.azurerm_arc_machine.main[0].id
}

output "extension_id" {
  value = azurerm_virtual_machine_extension.arc_onboarding.id
}
