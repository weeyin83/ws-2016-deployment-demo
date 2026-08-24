############################################
# Terraform & provider version constraints
############################################
# Pinned with "~>" so patch/minor upgrades are picked up automatically but
# breaking major-version changes require a deliberate bump.

terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.15"
    }

    # Only used to optionally auto-create the Arc onboarding service principal
    # (var.create_arc_service_principal = true). Safe to remove if you supply
    # an existing service principal instead.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    # Used only to create the short delay resource that lets Azure AD role
    # assignments propagate before azcmagent connect runs (see modules/arc-onboarding).
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
