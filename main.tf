############################################
# Resource group
############################################

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.common_tags
}

############################################
# Networking - one shared VNet/subnet/NSG
############################################

module "network" {
  source = "./modules/network"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  vnet_name     = local.vnet_name
  address_space = var.vnet_address_space

  subnet_name   = local.subnet_name
  subnet_prefix = var.subnet_address_prefix

  nsg_name = local.nsg_name

  # Only VMs with public RDP enabled generate an inbound allow rule; every
  # other VM gets no inbound rule at all (NSG default-denies inbound from
  # the internet already).
  rdp_rules = {
    for k, v in local.vm_configs : k => {
      source_cidr = v.trusted_rdp_source_cidr
    } if v.enable_public_rdp
  }

  tags = local.common_tags
}

############################################
# Optional: Entra ID service principal dedicated to Arc onboarding
# (least-privilege - only the "Azure Connected Machine Onboarding" role,
# scoped to this resource group).
############################################

resource "azuread_application" "arc_onboarding" {
  count        = var.create_arc_service_principal ? 1 : 0
  display_name = "spn-${local.name_prefix}-arc-onboarding"
}

resource "azuread_service_principal" "arc_onboarding" {
  count     = var.create_arc_service_principal ? 1 : 0
  client_id = azuread_application.arc_onboarding[0].client_id
}

resource "azuread_service_principal_password" "arc_onboarding" {
  count                = var.create_arc_service_principal ? 1 : 0
  service_principal_id = azuread_service_principal.arc_onboarding[0].id
  # 24h validity is enough to cover an onboarding demo window; recreate if the
  # demo runs longer. Kept short deliberately to limit exposure of the secret
  # that Terraform state will hold (see README "Terraform state security").
  end_date = timeadd(timestamp(), "24h")

  lifecycle {
    ignore_changes = [end_date]
  }
}

resource "azurerm_role_assignment" "arc_onboarding" {
  count = var.create_arc_service_principal ? 1 : 0

  scope                = azurerm_resource_group.main.id
  role_definition_name = "Azure Connected Machine Onboarding"
  principal_id         = azuread_service_principal.arc_onboarding[0].object_id
}

# Give Entra ID / RBAC a few seconds to propagate before azcmagent connect
# runs on the VMs. This is a real, documented Azure AD/RBAC propagation delay,
# not an arbitrary workaround - see README "Known limitations".
resource "time_sleep" "role_assignment_propagation" {
  count           = var.create_arc_service_principal ? 1 : 0
  depends_on      = [azurerm_role_assignment.arc_onboarding]
  create_duration = "30s"
}

locals {
  # Resolve the credentials actually used for Arc onboarding: either the
  # Terraform-created service principal, or an existing one supplied by the caller.
  arc_sp_client_id = var.create_arc_service_principal ? azuread_application.arc_onboarding[0].client_id : var.arc_service_principal_client_id
  arc_sp_secret    = var.create_arc_service_principal ? azuread_service_principal_password.arc_onboarding[0].value : var.arc_service_principal_secret
}

############################################
# Windows VMs - one reusable module, five instances via for_each
############################################

module "windows_vm" {
  for_each = local.vm_configs
  source   = "./modules/windows-vm"

  vm_key              = each.key
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = module.network.subnet_id

  admin_username = var.admin_username
  admin_password = var.admin_password

  vm_size                      = each.value.vm_size
  os_disk_storage_account_type = var.os_disk_storage_account_type
  image_reference              = local.os_images[each.value.os_edition]
  license_type                 = var.enable_azure_hybrid_benefit ? "Windows_Server" : "None"

  enable_public_ip = each.value.enable_public_ip

  auto_shutdown_enabled  = each.value.auto_shutdown_enabled
  auto_shutdown_time     = each.value.auto_shutdown_time
  auto_shutdown_timezone = var.auto_shutdown_timezone

  tags = local.vm_tags[each.key]
}

############################################
# Arc evaluation onboarding - applied only to management_type = arc-evaluation
############################################

module "arc_onboarding" {
  for_each = local.arc_vm_configs
  source   = "./modules/arc-onboarding"

  vm_id   = module.windows_vm[each.key].vm_id
  vm_name = each.key

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subscription_id     = var.subscription_id
  tenant_id           = var.tenant_id

  service_principal_client_id = local.arc_sp_client_id
  service_principal_secret    = local.arc_sp_secret

  tags = local.vm_tags[each.key]

  depends_on = [
    module.windows_vm,
    time_sleep.role_assignment_propagation,
    azurerm_role_assignment.arc_onboarding,
  ]
}
