############################################
# Provider configuration
############################################
# Authentication is NOT hard-coded here. azurerm/azuread will use, in order:
#   1. Environment variables: ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID,
#      ARM_SUBSCRIPTION_ID (or ARM_USE_OIDC=true for GitHub OIDC federation)
#   2. The current `az login` session (Azure CLI authentication)
# Never place credentials directly in these files.

provider "azurerm" {
  features {
    resource_group {
      # Allows `terraform destroy` to remove the resource group even if the
      # portal briefly still shows "locked" child resources being deleted.
      # Safe for a temporary demo environment; do not rely on this in production.
      prevent_deletion_if_contains_resources = false
    }
  }

  # This subscription enforces "shared key access disabled" on storage
  # accounts (Azure Policy), so container/blob data-plane operations must use
  # Azure AD (your az login / ARM_* identity) instead of the storage account
  # key. Requires the "Storage Blob Data Contributor" role - see main.tf.
  storage_use_azuread = true

  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# Only required when var.arc_onboarding_method = "service_principal_new", so that
# Terraform can register the Entra ID application/service principal used for Arc onboarding.
provider "azuread" {
  tenant_id = var.tenant_id
}
