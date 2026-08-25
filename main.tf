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
# Arc onboarding identity - one of three methods (see variables.tf for the
# full decision guide): a Terraform-created service principal, an existing
# caller-supplied service principal, or an interactively-connected human user.
#
# NOTE: creating an application + service principal via Microsoft Graph
# requires an Entra ID role such as Application Administrator or Cloud
# Application Administrator (or the Application.ReadWrite.All Graph
# permission). Some tenants (e.g. locked-down eval/sandbox tenants) block this
# entirely for every non-admin identity, even via `az ad sp create-for-rbac` -
# in that case use arc_onboarding_method = "interactive_user" instead, which
# only needs an Azure RBAC role assignment (a completely different permission
# model, typically covered by Owner/User Access Administrator).
############################################

locals {
  arc_create_sp    = var.arc_onboarding_method == "service_principal_new"
  arc_use_existing = var.arc_onboarding_method == "service_principal_existing"
  arc_interactive  = var.arc_onboarding_method == "interactive_user"
}

# Current caller - used as the default RBAC assignee for interactive_user mode.
# Reading your own identity requires no special permissions.
data "azurerm_client_config" "current" {}

resource "azuread_application" "arc_onboarding" {
  count        = local.arc_create_sp ? 1 : 0
  display_name = "spn-${local.name_prefix}-arc-onboarding"
}

# Microsoft Graph needs a few seconds to replicate a newly created application
# object before a service principal can be created for it. This does NOT fix
# a genuine permissions error (see note above) - only the rarer replication
# race some tenants exhibit.
resource "time_sleep" "app_replication" {
  count           = local.arc_create_sp ? 1 : 0
  depends_on      = [azuread_application.arc_onboarding]
  create_duration = "30s"
}

resource "azuread_service_principal" "arc_onboarding" {
  count      = local.arc_create_sp ? 1 : 0
  client_id  = azuread_application.arc_onboarding[0].client_id
  depends_on = [time_sleep.app_replication]
}

resource "azuread_service_principal_password" "arc_onboarding" {
  count                = local.arc_create_sp ? 1 : 0
  service_principal_id = azuread_service_principal.arc_onboarding[0].id
  # 24h validity is enough to cover an onboarding demo window; recreate if the
  # demo runs longer. Kept short deliberately to limit exposure of the secret
  # that Terraform state will hold (see README "Terraform state security").
  end_date = timeadd(timestamp(), "24h")

  lifecycle {
    ignore_changes = [end_date]
  }
}

# Looks up an existing, caller-supplied service principal by client ID.
# Read-only Graph data sources work for any authenticated user (no
# Application Administrator role required), unlike creating one above.
data "azuread_service_principal" "existing_arc_onboarding" {
  count     = local.arc_use_existing ? 1 : 0
  client_id = var.arc_service_principal_client_id
}

locals {
  # The RBAC role is granted to: the created SP, the existing SP, or a human
  # user/group (defaulting to whoever runs Terraform) for interactive_user mode.
  arc_role_principal_id = (
    local.arc_create_sp ? azuread_service_principal.arc_onboarding[0].object_id :
    local.arc_use_existing ? data.azuread_service_principal.existing_arc_onboarding[0].object_id :
    var.interactive_onboarding_principal_id != "" ? var.interactive_onboarding_principal_id :
    data.azurerm_client_config.current.object_id
  )
}

# Role assignment runs unconditionally - every method needs this least-
# privilege role at the RG scope, whether held by a service principal or a
# human user. Assigning RBAC roles needs Owner/User Access Administrator -
# a separate permission model from Entra ID app/SP creation.
resource "azurerm_role_assignment" "arc_onboarding" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Azure Connected Machine Onboarding"
  principal_id         = local.arc_role_principal_id
}

# Give Entra ID / RBAC a few seconds to propagate before azcmagent connect
# runs on the VMs. This is a real, documented Azure AD/RBAC propagation delay,
# not an arbitrary workaround - see README "Known limitations".
resource "time_sleep" "role_assignment_propagation" {
  depends_on      = [azurerm_role_assignment.arc_onboarding]
  create_duration = "30s"
}

locals {
  # Resolve the credentials actually used for Arc onboarding: either the
  # Terraform-created service principal, or an existing one supplied by the
  # caller. Left as empty strings in interactive_user mode - the module skips
  # the automated connect step entirely in that case.
  arc_sp_client_id = local.arc_create_sp ? azuread_application.arc_onboarding[0].client_id : var.arc_service_principal_client_id
  arc_sp_secret    = local.arc_create_sp ? azuread_service_principal_password.arc_onboarding[0].value : var.arc_service_principal_secret
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
# SQL Server demo data - applied only to VMs using the sql-server-2016-developer image
############################################

module "sql_demo_data" {
  for_each = local.sql_demo_vm_configs
  source   = "./modules/sql-demo-data"

  vm_id   = module.windows_vm[each.key].vm_id
  vm_name = each.key
  tags    = local.vm_tags[each.key]
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
  interactive_mode            = local.arc_interactive

  tags = local.vm_tags[each.key]

  depends_on = [
    module.windows_vm,
    time_sleep.role_assignment_propagation,
    azurerm_role_assignment.arc_onboarding,
  ]
}
