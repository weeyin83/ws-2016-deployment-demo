<#
.SYNOPSIS
    Connects this machine to Azure Arc-enabled servers using a service principal.

.DESCRIPTION
    Standalone reference/manual-use version of the connect step also
    performed automatically by modules/arc-onboarding via CustomScriptExtension.

    Credentials are accepted as SecureString parameters only - this script
    never stores, logs, or hard-codes the service principal secret. Pass the
    secret interactively (you will be prompted if -ServicePrincipalSecret is
    omitted) or from a secure secret store already resolved in memory by your
    calling process. Do not pass the secret as plain command-line text where
    it could be captured in shell history or process listings.

.NOTES
    Run this BEFORE the Azure Windows VM Guest Agent is disabled.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$ResourceName,

    [Parameter(Mandatory = $true)]
    [string]$ServicePrincipalId,

    [Parameter(Mandatory = $true)]
    [Security.SecureString]$ServicePrincipalSecret,

    [string]$Cloud = "AzureCloud"
)

$ErrorActionPreference = "Stop"

$azcmagent = Join-Path $env:ProgramFiles "AzureConnectedMachineAgent\azcmagent.exe"
if (-not (Test-Path $azcmagent)) {
    throw "azcmagent.exe not found. Run Install-ArcConnectedMachineAgent.ps1 first."
}

# azcmagent.exe takes the secret as a plain argument; convert only in-memory,
# immediately before the call, and never write it to a variable that gets logged.
$plainSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ServicePrincipalSecret)
)

try {
    & $azcmagent connect `
        --service-principal-id $ServicePrincipalId `
        --service-principal-secret $plainSecret `
        --resource-group $ResourceGroupName `
        --tenant-id $TenantId `
        --subscription-id $SubscriptionId `
        --location $Location `
        --resource-name $ResourceName `
        --cloud $Cloud `
        --tags "ArcEvaluation=true"

    if ($LASTEXITCODE -ne 0) {
        throw "azcmagent connect failed with exit code $LASTEXITCODE"
    }
} finally {
    # Best-effort clearing of the in-memory plaintext copy.
    Remove-Variable -Name plainSecret -ErrorAction SilentlyContinue
}

Write-Output "Verifying connection..."
& $azcmagent show
Write-Output "Arc onboarding connect step complete."
