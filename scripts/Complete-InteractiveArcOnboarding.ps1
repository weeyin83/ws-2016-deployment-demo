<#
.SYNOPSIS
    Completes Azure Arc evaluation onboarding interactively, using your own
    Microsoft Entra credentials instead of a service principal.

.DESCRIPTION
    Use this when arc_onboarding_method = "interactive_user" was set in
    Terraform (typically because the tenant blocks Entra app/service
    principal creation for your account - e.g. `az ad sp create-for-rbac`
    fails with "Insufficient privileges to complete the operation").

    Terraform's CustomScriptExtension already completed the automatable part
    (MSFT_ARC_TEST env var, IMDS/WireServer firewall rules, Connected Machine
    agent install) and granted your account (or the principal you specified
    via interactive_onboarding_principal_id) the "Azure Connected Machine
    Onboarding" RBAC role on the resource group. This script finishes the
    job: it runs `azcmagent connect` WITHOUT a service principal, which
    triggers an interactive device-code/browser login using your own
    credentials, then schedules the deferred Guest Agent disable.

    Run this via RDP or Azure Serial Console, once per Arc evaluation VM
    (arc-vm01, arc-vm02, arc-vm03).

.NOTES
    This cannot be automated end-to-end: device-code login requires a human
    to visit a URL and enter a code in a browser, which a CustomScriptExtension
    (running unattended as SYSTEM, with no interactive session) cannot do.
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

    [string]$Cloud = "AzureCloud"
)

$ErrorActionPreference = "Stop"

$azcmagent = Join-Path $env:ProgramFiles "AzureConnectedMachineAgent\azcmagent.exe"
if (-not (Test-Path $azcmagent)) {
    throw "azcmagent.exe not found. Run Install-ArcConnectedMachineAgent.ps1 first."
}

Write-Output "Running azcmagent connect - a browser/device-code login prompt will appear."
Write-Output "Sign in with an account that holds the 'Azure Connected Machine Onboarding' role on $ResourceGroupName."
& $azcmagent connect --resource-group $ResourceGroupName --tenant-id $TenantId `
    --subscription-id $SubscriptionId --location $Location --resource-name $ResourceName `
    --cloud $Cloud --tags "ArcEvaluation=true"

if ($LASTEXITCODE -ne 0) {
    throw "azcmagent connect failed with exit code $LASTEXITCODE"
}

Write-Output "Verifying connection..."
& $azcmagent show
if ($LASTEXITCODE -ne 0) {
    throw "azcmagent show reported a non-zero exit code after connect"
}

# Defer the Guest Agent disable (do not disable inline): if this session is
# itself reached via a mechanism that depends on the Guest Agent, disabling
# it immediately could cut off your own access before you can confirm success.
$disableScriptPath = "C:\ArcEvaluation\Disable-GuestAgentDeferred.ps1"
if (-not (Test-Path $disableScriptPath)) {
    New-Item -ItemType Directory -Path "C:\ArcEvaluation" -Force | Out-Null
    @'
$ErrorActionPreference = "SilentlyContinue"
Start-Transcript -Path "C:\ArcEvaluation\disable-guest-agent.log" -Append
try {
    Stop-Service -Name "WindowsAzureGuestAgent" -Force
    Set-Service -Name "WindowsAzureGuestAgent" -StartupType Disabled
    Write-Output "$(Get-Date -Format o) - Azure Windows VM Guest Agent stopped and disabled."
} finally {
    Unregister-ScheduledTask -TaskName "ArcEval-DisableGuestAgent" -Confirm:$false -ErrorAction SilentlyContinue
    Stop-Transcript
}
'@ | Set-Content -Path $disableScriptPath -Encoding UTF8
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$disableScriptPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "ArcEval-DisableGuestAgent" -Action $action `
    -Trigger $trigger -Principal $principal -Force | Out-Null

Write-Output "Interactive Arc onboarding complete. Guest Agent will be disabled in ~5 minutes."
