<#
.SYNOPSIS
    Reverses the Arc evaluation configuration on this machine.

.DESCRIPTION
    Run this after testing is complete and BEFORE (or instead of) deleting
    the VM, if you want to leave the machine in a clean, reusable state:
      1. Disconnects the machine from Azure Arc (azcmagent disconnect).
      2. Uninstalls the Azure Connected Machine agent.
      3. Re-enables and starts the Azure Windows VM Guest Agent.
      4. Removes the persistent IMDS/WireServer-blocking firewall rules.
      5. Clears the MSFT_ARC_TEST machine environment variable.

    This script must be run interactively (e.g. via RDP or Azure Serial
    Console) - Azure VM extensions cannot run reliably once the Guest Agent
    has been disabled, which is precisely the state this script starts from.

.NOTES
    If you only want to delete everything, skip this script and simply run
    `terraform destroy` (see README "Cleanup") - it removes the Azure VM and,
    separately, you should also delete the corresponding Azure Arc machine
    resource (this script's disconnect step does that for you cleanly).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServicePrincipalId,

    [Parameter(Mandatory = $true)]
    [Security.SecureString]$ServicePrincipalSecret,

    [string]$TenantId
)

$ErrorActionPreference = "Continue"

$azcmagent = Join-Path $env:ProgramFiles "AzureConnectedMachineAgent\azcmagent.exe"
if (Test-Path $azcmagent) {
    Write-Output "Disconnecting from Azure Arc..."
    $plainSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ServicePrincipalSecret)
    )
    try {
        $args = @("disconnect", "--service-principal-id", $ServicePrincipalId, "--service-principal-secret", $plainSecret)
        if ($TenantId) { $args += @("--tenant-id", $TenantId) }
        & $azcmagent @args
    } finally {
        Remove-Variable -Name plainSecret -ErrorAction SilentlyContinue
    }

    Write-Output "Uninstalling Azure Connected Machine agent..."
    $uninstallKey = Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall" |
    Get-ItemProperty | Where-Object { $_.DisplayName -like "Azure Connected Machine Agent*" }
    if ($uninstallKey) {
        Start-Process "msiexec.exe" -ArgumentList @("/x", $uninstallKey.PSChildName, "/qn", "/norestart") -Wait
    } else {
        Write-Warning "Could not find the agent's uninstall registry entry - uninstall manually via 'Apps & features' if needed."
    }
} else {
    Write-Output "Azure Connected Machine agent not installed - skipping disconnect/uninstall."
}

Write-Output "Re-enabling Azure Windows VM Guest Agent..."
Set-Service -Name "WindowsAzureGuestAgent" -StartupType Automatic
Start-Service -Name "WindowsAzureGuestAgent"

Write-Output "Removing IMDS/WireServer firewall block rules..."
foreach ($name in @("Block-Outbound-IMDS", "Block-Outbound-WireServer")) {
    Remove-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
}

Write-Output "Clearing MSFT_ARC_TEST environment variable..."
[Environment]::SetEnvironmentVariable("MSFT_ARC_TEST", $null, "Machine")

Write-Output "Arc evaluation configuration removed. The VM is now a standard Azure VM again."
