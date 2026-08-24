<#
.SYNOPSIS
    Verifies the Azure Arc evaluation configuration on this machine.

.DESCRIPTION
    Checks, and prints a pass/fail summary for, each expected condition of an
    Arc evaluation VM:
      - MSFT_ARC_TEST machine environment variable is set to true.
      - Persistent Windows Firewall rules blocking IMDS/WireServer exist and
        are enabled.
      - The Azure Windows VM Guest Agent service is stopped and disabled.
      - The Azure Connected Machine agent is installed and connected
        (azcmagent show reports "Connected").

    Run this any time after onboarding to confirm the evaluation environment
    is in the expected state, e.g. from an RDP session or Azure Serial Console
    (remember: Azure VM extensions can no longer run reliably once the Guest
    Agent has been disabled).
#>

[CmdletBinding()]
param()

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Check, [bool]$Passed, [string]$Detail)
    $results.Add([pscustomobject]@{ Check = $Check; Passed = $Passed; Detail = $Detail })
}

# 1. MSFT_ARC_TEST
$arcTest = [Environment]::GetEnvironmentVariable("MSFT_ARC_TEST", "Machine")
Add-Result -Check "MSFT_ARC_TEST=true" -Passed ($arcTest -eq "true") -Detail "Current value: '$arcTest'"

# 2. Firewall rules
foreach ($name in @("Block-Outbound-IMDS", "Block-Outbound-WireServer")) {
    $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    $ok = $null -ne $rule -and $rule.Enabled -eq "True" -and $rule.Action -eq "Block"
    $detail = if ($rule) { "Enabled=$($rule.Enabled) Action=$($rule.Action)" } else { "Not found" }
    Add-Result -Check "Firewall rule '$name'" -Passed $ok -Detail $detail
}

# 3. Guest Agent disabled
$svc = Get-Service -Name "WindowsAzureGuestAgent" -ErrorAction SilentlyContinue
$guestAgentOk = $null -ne $svc -and $svc.Status -eq "Stopped" -and (Get-CimInstance Win32_Service -Filter "Name='WindowsAzureGuestAgent'").StartMode -eq "Disabled"
$guestAgentDetail = if ($svc) { "Status=$($svc.Status)" } else { "Service not found" }
Add-Result -Check "Guest Agent stopped and disabled" -Passed $guestAgentOk -Detail $guestAgentDetail

# 4. Azure Connected Machine agent connected
$azcmagent = Join-Path $env:ProgramFiles "AzureConnectedMachineAgent\azcmagent.exe"
if (Test-Path $azcmagent) {
    $showOutput = & $azcmagent show 2>&1 | Out-String
    $connected = $showOutput -match "Status\s*:\s*Connected"
    $connectedDetail = if ($connected) { "Connected" } else { $showOutput.Trim() }
    Add-Result -Check "azcmagent connected" -Passed $connected -Detail $connectedDetail
} else {
    Add-Result -Check "azcmagent connected" -Passed $false -Detail "azcmagent.exe not found - agent not installed"
}

$results | Format-Table -AutoSize

if ($results | Where-Object { -not $_.Passed }) {
    Write-Warning "One or more Arc evaluation checks failed - see table above."
    exit 1
} else {
    Write-Output "All Arc evaluation checks passed."
    exit 0
}
