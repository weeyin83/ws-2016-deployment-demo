<#
.SYNOPSIS
    Prepares an Azure VM for Azure Arc-enabled servers EVALUATION ONLY.

.DESCRIPTION
    Implements the guidance at:
    https://learn.microsoft.com/en-us/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine

    This is UNSUPPORTED for production. Connecting an Azure VM to Azure Arc is
    only permitted for evaluation/testing when the VM is deliberately made to
    look like a non-Azure machine, which is what this script does:
      - Sets the MSFT_ARC_TEST machine environment variable to true.
      - Creates persistent Windows Firewall rules blocking outbound access to
        the Azure Instance Metadata Service (169.254.169.254) and the Azure
        WireServer (169.254.169.253).

    Run this BEFORE installing the Connected Machine agent, and BEFORE
    disabling the Azure Windows VM Guest Agent (see
    Remove-ArcEvaluationConfiguration.ps1 for the reverse of this script).

    NOTE: This script does not disable the Guest Agent itself - Terraform's
    modules/arc-onboarding defers that step via a Scheduled Task, run AFTER
    Arc onboarding has completed, so that any Guest-Agent-dependent operation
    (like this very CustomScriptExtension) can finish and report success.

.NOTES
    Intended to run elevated (SYSTEM/Administrator) on Windows Server 2016.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Write-Output "Setting MSFT_ARC_TEST machine environment variable..."
[Environment]::SetEnvironmentVariable("MSFT_ARC_TEST", "true", "Machine")

Write-Output "Creating persistent Windows Firewall rules blocking IMDS/WireServer..."
$blockedEndpoints = @(
    @{ Name = "Block-Outbound-IMDS"; Addr = "169.254.169.254" },
    @{ Name = "Block-Outbound-WireServer"; Addr = "169.254.169.253" }
)

foreach ($ep in $blockedEndpoints) {
    if (-not (Get-NetFirewallRule -DisplayName $ep.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $ep.Name -Direction Outbound -Action Block `
            -RemoteAddress $ep.Addr -Profile Any -Enabled True | Out-Null
        Write-Output "Created firewall rule: $($ep.Name) -> $($ep.Addr)"
    } else {
        Write-Output "Firewall rule already present: $($ep.Name)"
    }
}

Write-Output ""
Write-Output "Reminder: 'incompatible extension removal' must be done at the Azure Resource"
Write-Output "Manager level (az vm extension delete / Terraform), not from inside the guest OS."
Write-Output "Verify no unexpected extensions are attached to this VM before proceeding."
Write-Output ""
Write-Output "Arc evaluation prep complete."
