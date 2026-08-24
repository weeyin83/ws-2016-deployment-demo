<#
.SYNOPSIS
    Downloads and installs the Azure Connected Machine agent (azcmagent).

.DESCRIPTION
    Standalone reference/manual-use version of the install step also
    performed automatically by modules/arc-onboarding via CustomScriptExtension.
    Use this if you need to (re)install the agent manually, e.g. while
    troubleshooting, or when re-running onboarding outside of Terraform.

.NOTES
    Run this BEFORE the Azure Windows VM Guest Agent is disabled - after that
    point, Azure VM extension-based automation can no longer reach the VM
    reliably, and this script would need to be run interactively instead
    (e.g. via RDP or Azure Serial Console).
#>

[CmdletBinding()]
param(
    [string]$LogDirectory = "C:\ArcEvaluation"
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

$installerPath = Join-Path $LogDirectory "AzureConnectedMachineAgent.msi"

Write-Output "Downloading Azure Connected Machine agent..."
$downloadAttempts = 0
do {
    $downloadAttempts++
    try {
        Invoke-WebRequest -Uri "https://aka.ms/AzureConnectedMachineAgent" -OutFile $installerPath -UseBasicParsing
        break
    } catch {
        Write-Warning "Download attempt $downloadAttempts failed: $_"
        if ($downloadAttempts -ge 3) { throw }
        Start-Sleep -Seconds 15
    }
} while ($downloadAttempts -lt 3)

Write-Output "Installing Azure Connected Machine agent..."
$msiLog = Join-Path $LogDirectory "agent-install.log"
$proc = Start-Process -FilePath "msiexec.exe" `
    -ArgumentList @("/i", "`"$installerPath`"", "/qn", "/norestart", "/l*v", "`"$msiLog`"") `
    -Wait -PassThru

if ($proc.ExitCode -ne 0) {
    throw "Azure Connected Machine agent install failed with exit code $($proc.ExitCode). See $msiLog."
}

$azcmagent = Join-Path $env:ProgramFiles "AzureConnectedMachineAgent\azcmagent.exe"
if (-not (Test-Path $azcmagent)) {
    throw "Installation appeared to succeed but azcmagent.exe was not found at $azcmagent"
}

& $azcmagent version
Write-Output "Azure Connected Machine agent installed successfully."
