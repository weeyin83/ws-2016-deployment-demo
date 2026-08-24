############################################
# Naming
############################################

locals {
  # Short region code used only in generated names (CAF-style abbreviation).
  location_short = "swc"

  name_prefix = "${var.workload_name}-${var.environment}-${local.location_short}-${var.instance}"

  resource_group_name = "rg-${local.name_prefix}"
  vnet_name           = "vnet-${local.name_prefix}"
  subnet_name         = "snet-${local.name_prefix}"
  nsg_name            = "nsg-${local.name_prefix}"

  common_tags = merge(
    {
      environment          = var.environment
      workload             = var.workload_name
      purpose              = "azure-arc-evaluation-demo"
      managedBy            = "terraform"
      owner                = var.owner
      temporary            = "true"
      intendedDeletionDate = var.intended_deletion_date
    },
    var.additional_tags
  )
}

############################################
# Verified Windows Server 2016 Marketplace image
############################################
# IMPORTANT: Verified via `az vm image list --publisher MicrosoftWindowsServer
# --offer WindowsServer --location swedencentral` on 2026-08-24.
#
# Windows Server 2016 is published ONLY as the "2016-Datacenter" SKU. There is
# NO "2016-Standard" SKU in the Azure Marketplace, in Sweden Central or any
# other region, for this or any other publisher. Per explicit user instruction,
# all VMs use Datacenter edition instead of a Standard/Datacenter mix.
#
# Do not add a "windows-server-2016-standard" entry here without first
# re-verifying (a non-existent image would fail at apply time with a
# confusing "SkuNotFound" error).
locals {
  os_images = {
    "windows-server-2016-datacenter" = {
      publisher = "MicrosoftWindowsServer"
      offer     = "WindowsServer"
      sku       = "2016-Datacenter"
      version   = "14393.9418.260809" # latest verified in swedencentral; consider "latest" if you re-verify regularly
    }
    # Verified via `az vm image list --publisher MicrosoftSQLServer --offer
    # SQL2016SP2-WS2016 --sku SQLDEV --location swedencentral` on 2026-08-24.
    # SQL Server 2016 SP2 Developer edition on Windows Server 2016 - Developer
    # is functionally identical to Enterprise (full feature set) but licensed
    # free for non-production use, which matches this demo environment. Do not
    # use this for production - see README for the Standard-edition PAYG
    # alternative if you need to validate licensed-tier behavior.
    "sql-server-2016-developer" = {
      publisher = "MicrosoftSQLServer"
      offer     = "SQL2016SP2-WS2016"
      sku       = "SQLDEV"
      version   = "13.2.230912" # latest verified in swedencentral
    }
  }
}

############################################
# VM configuration - merge user input with defaults
############################################

locals {
  vm_configs = {
    for k, v in var.vm_configs : k => merge(v, {
      vm_size               = coalesce(v.vm_size, var.default_vm_size)
      auto_shutdown_enabled = coalesce(v.auto_shutdown_enabled, var.default_auto_shutdown_enabled)
      auto_shutdown_time    = coalesce(v.auto_shutdown_time, var.default_auto_shutdown_time)
    })
  }

  arc_vm_configs    = { for k, v in local.vm_configs : k => v if v.management_type == "arc-evaluation" }
  native_vm_configs = { for k, v in local.vm_configs : k => v if v.management_type == "native-azure" }

  # VMs running the SQL Server 2016 Developer image get the AdventureWorks2016
  # demo database restored automatically - see modules/sql-demo-data.
  sql_demo_vm_configs = { for k, v in local.vm_configs : k => v if v.os_edition == "sql-server-2016-developer" }

  # Per-VM tags layered on top of common_tags, clearly distinguishing Arc
  # evaluation resources from native Azure resources and recording the
  # Windows Server edition, as required for governance/reporting.
  # NOTE: tag key is "osEdition", not "windowsServerEdition" - Azure rejects
  # any tag NAME starting with the reserved prefixes microsoft/azure/windows.
  vm_tags = {
    for k, v in local.vm_configs : k => merge(
      local.common_tags,
      {
        managementType    = v.management_type
        osEdition         = v.os_edition
        arcEvaluationOnly = v.management_type == "arc-evaluation" ? "true" : "false"
      },
      v.additional_tags
    )
  }
}
