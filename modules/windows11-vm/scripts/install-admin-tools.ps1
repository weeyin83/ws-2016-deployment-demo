$ErrorActionPreference = 'Stop'
# WS2016 gotcha doesn't apply here (Windows 11 ships TLS 1.2 by default), but
# forcing it is a harmless no-op safeguard for any older TLS defaults.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$logPath = 'C:\WindowsAzure\Logs\install-admin-tools.log'
New-Item -ItemType Directory -Force -Path (Split-Path $logPath) | Out-Null
Start-Transcript -Path $logPath -Append

try {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path += ";$env:ProgramData\chocolatey\bin"

    choco install azure-cli -y --no-progress
    choco install powerbi -y --no-progress
    choco install sql-server-management-studio -y --no-progress
} finally {
    Stop-Transcript
}
