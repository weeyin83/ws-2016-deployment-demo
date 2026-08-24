############################################
# Core / naming variables
############################################

variable "subscription_id" {
  description = "Azure subscription ID to deploy into. Supply via TF_VAR_subscription_id or terraform.tfvars (do not hard-code in shared files)."
  type        = string
  sensitive   = true
}

variable "tenant_id" {
  description = "Microsoft Entra tenant ID. Supply via TF_VAR_tenant_id or terraform.tfvars."
  type        = string
  sensitive   = true
}

variable "workload_name" {
  description = "Short workload/project name used in resource naming, e.g. 'ws16arc'."
  type        = string
  default     = "ws16arc"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.workload_name))
    error_message = "workload_name must be 3-12 lowercase alphanumeric characters."
  }
}

variable "environment" {
  description = "Environment tag/name segment, e.g. 'demo'."
  type        = string
  default     = "demo"

  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.environment))
    error_message = "environment must be 2-10 lowercase alphanumeric characters."
  }
}

variable "location" {
  description = "Azure region. Verified for Windows Server 2016 Datacenter image availability at time of writing: Sweden Central only. Changing this requires re-verifying image availability."
  type        = string
  default     = "swedencentral"

  validation {
    condition     = var.location == "swedencentral"
    error_message = "This configuration has only been verified against Sweden Central (swedencentral). Re-verify Windows Server 2016 image availability before changing region."
  }
}

variable "instance" {
  description = "Instance/sequence suffix used in shared resource names (resource group, vnet, subnet, nsg)."
  type        = string
  default     = "01"

  validation {
    condition     = can(regex("^[0-9]{2}$", var.instance))
    error_message = "instance must be a two-digit numeric string, e.g. '01'."
  }
}

variable "owner" {
  description = "Owner tag value (person or team responsible for this temporary environment)."
  type        = string
  default     = "unspecified-owner"
}

variable "intended_deletion_date" {
  description = "Planned teardown date for this temporary demo environment, used only as a tag (YYYY-MM-DD). Not enforced automatically."
  type        = string
  default     = "unspecified"

  validation {
    condition     = var.intended_deletion_date == "unspecified" || can(regex("^\\d{4}-\\d{2}-\\d{2}$", var.intended_deletion_date))
    error_message = "intended_deletion_date must be 'unspecified' or in YYYY-MM-DD format."
  }
}

variable "additional_tags" {
  description = "Optional extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}

############################################
# Networking
############################################

variable "vnet_address_space" {
  description = "Address space for the single shared virtual network."
  type        = list(string)
  default     = ["10.60.0.0/24"]
}

variable "subnet_address_prefix" {
  description = "Address prefix for the single shared subnet used by all five VMs."
  type        = list(string)
  default     = ["10.60.0.0/26"]
}

############################################
# Administrator credentials
############################################

variable "admin_username" {
  description = "Local administrator username applied to all VMs. Avoid well-known/reserved names."
  type        = string
  default     = "azdemoadmin"

  validation {
    condition     = !contains(["administrator", "admin", "root", "guest"], lower(var.admin_username))
    error_message = "admin_username must not be a reserved/well-known name (administrator, admin, root, guest)."
  }
}

variable "admin_password" {
  description = <<-EOT
    Local administrator password for all VMs. NO DEFAULT is provided - you must supply this
    securely, e.g.:
      export TF_VAR_admin_password="$(pass show demo/vm-admin)"
    or via a CI/CD secret store. Never commit this value to terraform.tfvars.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 12
    error_message = "admin_password must be at least 12 characters to meet Azure VM complexity requirements."
  }
}

############################################
# VM sizing / cost controls
############################################

variable "default_vm_size" {
  description = "Default Azure VM size for all VMs unless overridden per-VM. Standard_B2s_v2 (2 vCPU/4GB, burstable) is the lowest-cost size confirmed available in Sweden Central that reliably supports Windows Server 2016 and the Azure Connected Machine agent's minimum requirements."
  type        = string
  default     = "Standard_B2s_v2"
}

variable "os_disk_storage_account_type" {
  description = "OS disk storage type. Standard_LRS (Standard HDD) keeps this temporary demo low-cost; only override if a specific VM has a technical reason to need Premium/SSD."
  type        = string
  default     = "Standard_LRS"

  validation {
    condition     = contains(["Standard_LRS", "StandardSSD_LRS", "Premium_LRS"], var.os_disk_storage_account_type)
    error_message = "os_disk_storage_account_type must be one of Standard_LRS, StandardSSD_LRS, Premium_LRS."
  }
}

variable "enable_azure_hybrid_benefit" {
  description = "Optional: apply Azure Hybrid Benefit (license_type = Windows_Server) to reduce Windows licensing cost. Defaults to disabled. Only enable this if you hold qualifying on-premises Windows Server licences with Software Assurance (or equivalent) - enabling it without qualifying licences is a licensing compliance violation."
  type        = bool
  default     = false
}

############################################
# Auto-shutdown (uses the built-in, free
# Microsoft.DevTestLab auto-shutdown schedule
# feature - NOT an Azure DevTest Labs instance).
############################################

variable "default_auto_shutdown_enabled" {
  description = "Default auto-shutdown toggle applied to VMs that don't override auto_shutdown_enabled in var.vm_configs."
  type        = bool
  default     = true
}

variable "default_auto_shutdown_time" {
  description = "Default daily auto-shutdown time in HHmm (24h, local to auto_shutdown_timezone)."
  type        = string
  default     = "1900"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.default_auto_shutdown_time))
    error_message = "default_auto_shutdown_time must be in 24-hour HHmm format, e.g. 1900."
  }
}

variable "auto_shutdown_timezone" {
  description = "Windows time zone ID used for the auto-shutdown schedule."
  type        = string
  default     = "W. Europe Standard Time"
}

############################################
# Arc onboarding authentication method
############################################
# Three mutually exclusive ways to authenticate azcmagent connect on the
# three Arc evaluation VMs, in decreasing order of automation:
#   - "service_principal_new"      : Terraform creates the Entra app/SP (needs
#                                    Application Administrator/equivalent).
#   - "service_principal_existing" : you supply an already-created SP (needs
#                                    no Entra admin role, only someone who can
#                                    create app registrations to have made it).
#   - "interactive_user"           : no Entra app/SP at all. Terraform grants
#                                    the RBAC role directly to a user/group
#                                    (Azure RBAC only - no Entra admin role
#                                    needed), and a human runs `azcmagent
#                                    connect` interactively (device code login)
#                                    via RDP/Serial Console. Use this when your
#                                    tenant blocks app/SP creation entirely
#                                    (e.g. "Insufficient privileges" from
#                                    `az ad sp create-for-rbac`).

variable "arc_onboarding_method" {
  description = "How the three Arc evaluation VMs authenticate Azure Arc onboarding: 'service_principal_new', 'service_principal_existing', or 'interactive_user'."
  type        = string
  default     = "service_principal_new"

  validation {
    condition     = contains(["service_principal_new", "service_principal_existing", "interactive_user"], var.arc_onboarding_method)
    error_message = "arc_onboarding_method must be one of: service_principal_new, service_principal_existing, interactive_user."
  }
}

variable "arc_service_principal_client_id" {
  description = "Client (application) ID of an existing service principal to use for Arc onboarding, when arc_onboarding_method = 'service_principal_existing'."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.arc_onboarding_method != "service_principal_existing" || length(var.arc_service_principal_client_id) > 0
    error_message = "arc_service_principal_client_id must be set when arc_onboarding_method = 'service_principal_existing'."
  }
}

variable "arc_service_principal_secret" {
  description = "Client secret of an existing service principal to use for Arc onboarding, when arc_onboarding_method = 'service_principal_existing'."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.arc_onboarding_method != "service_principal_existing" || length(var.arc_service_principal_secret) > 0
    error_message = "arc_service_principal_secret must be set when arc_onboarding_method = 'service_principal_existing'."
  }
}

variable "interactive_onboarding_principal_id" {
  description = "Microsoft Entra object ID of the user/group to grant the 'Azure Connected Machine Onboarding' RBAC role to, when arc_onboarding_method = 'interactive_user'. Leave empty to default to the identity currently running Terraform (az login / ARM_* credentials)."
  type        = string
  default     = ""
}


############################################
# VM configuration map
############################################
# Single typed object map driving all 5 VMs through one reusable module
# (modules/windows-vm) via for_each - see locals.tf for defaults/merging and
# cross-field validation (preconditions).

variable "vm_configs" {
  description = "Map of VM key => configuration object. See README for full field descriptions."
  type = map(object({
    management_type         = string           # "arc-evaluation" | "native-azure"
    os_edition              = string           # "windows-server-2016-datacenter" (only supported value - see README)
    vm_size                 = optional(string) # overrides default_vm_size when set
    enable_public_ip        = optional(bool, false)
    enable_public_rdp       = optional(bool, false)
    trusted_rdp_source_cidr = optional(string)
    auto_shutdown_enabled   = optional(bool)
    auto_shutdown_time      = optional(string)
    additional_tags         = optional(map(string), {})
  }))

  default = {
    "arc-vm01" = {
      management_type = "arc-evaluation"
      os_edition      = "windows-server-2016-datacenter"
    }
    "arc-vm02" = {
      management_type = "arc-evaluation"
      os_edition      = "windows-server-2016-datacenter"
    }
    "arc-vm03" = {
      management_type = "arc-evaluation"
      os_edition      = "windows-server-2016-datacenter"
    }
    "native-vm01" = {
      management_type = "native-azure"
      os_edition      = "windows-server-2016-datacenter"
    }
    "native-vm02" = {
      management_type = "native-azure"
      os_edition      = "windows-server-2016-datacenter"
    }
  }

  validation {
    condition     = alltrue([for k, v in var.vm_configs : contains(["arc-evaluation", "native-azure"], v.management_type)])
    error_message = "Each VM's management_type must be 'arc-evaluation' or 'native-azure'."
  }

  validation {
    # Windows Server 2016 Standard is NOT published in the Azure Marketplace (verified
    # empirically in Sweden Central and globally). Only Datacenter is available, so this
    # is the only supported edition value. See README "Windows Server edition availability".
    condition     = alltrue([for k, v in var.vm_configs : v.os_edition == "windows-server-2016-datacenter"])
    error_message = "os_edition must be 'windows-server-2016-datacenter' - Windows Server 2016 Standard has no Azure Marketplace image and is not selectable."
  }

  validation {
    condition     = alltrue([for k, v in var.vm_configs : v.enable_public_ip || !v.enable_public_rdp])
    error_message = "enable_public_rdp cannot be true when enable_public_ip is false - a public IP is required for public RDP."
  }

  validation {
    condition     = alltrue([for k, v in var.vm_configs : !v.enable_public_rdp || (v.trusted_rdp_source_cidr != null && v.trusted_rdp_source_cidr != "")])
    error_message = "enable_public_rdp requires trusted_rdp_source_cidr to be set."
  }

  validation {
    condition     = alltrue([for k, v in var.vm_configs : v.trusted_rdp_source_cidr == null || !contains(["0.0.0.0/0", "*", "Internet", "internet"], v.trusted_rdp_source_cidr)])
    error_message = "trusted_rdp_source_cidr must never be 0.0.0.0/0, '*', or 'Internet' - RDP must never be exposed to the whole internet."
  }
}
