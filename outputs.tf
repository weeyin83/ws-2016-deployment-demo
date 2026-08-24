############################################
# Outputs - no secrets, passwords, or SP credentials are output.
############################################

output "resource_group_name" {
  description = "Name of the resource group containing the demo environment."
  value       = azurerm_resource_group.main.name
}

output "location" {
  description = "Azure region used for deployment."
  value       = azurerm_resource_group.main.location
}

output "virtual_network_name" {
  description = "Name of the shared virtual network."
  value       = module.network.vnet_name
}

output "subnet_id" {
  description = "Resource ID of the shared subnet used by all VMs."
  value       = module.network.subnet_id
}

output "vm_summary" {
  description = "Per-VM summary: management type, Windows Server edition, private IP, and public IP (if any)."
  value = {
    for k, v in module.windows_vm : k => {
      management_type        = local.vm_configs[k].management_type
      windows_server_edition = local.vm_configs[k].os_edition
      private_ip_address     = v.private_ip_address
      public_ip_address      = v.public_ip_address
      azure_vm_resource_id   = v.vm_id
      portal_url             = "https://portal.azure.com/#@/resource${v.vm_id}/overview"
    }
  }
}

output "arc_evaluation_vm_names" {
  description = "Names of the three VMs configured for Azure Arc evaluation (unsupported for production - evaluation/testing only)."
  value       = keys(local.arc_vm_configs)
}

output "native_azure_vm_names" {
  description = "Names of the two VMs kept as standard, unmodified native Azure VMs."
  value       = keys(local.native_vm_configs)
}

output "arc_enabled_server_resource_ids" {
  description = "Resource IDs of the Azure Arc-enabled server (Microsoft.HybridCompute/machines) objects created by onboarding, keyed by VM name."
  value       = { for k, v in module.arc_onboarding : k => v.arc_machine_resource_id }
}

output "arc_evaluation_warning" {
  description = "Mandatory reminder about the Arc evaluation configuration."
  value       = "The VMs listed in arc_evaluation_vm_names are Azure VMs deliberately reconfigured to look like non-Azure machines so they can be connected to Azure Arc-enabled servers. This is UNSUPPORTED for production and is for evaluation/testing only. See README.md."
}
