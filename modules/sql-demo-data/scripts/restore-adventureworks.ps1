<#
  Downloads the official Microsoft AdventureWorks2016 sample database backup
  and restores it into the local default SQL Server instance. Runs once, via
  a CustomScriptExtension, on VMs using the sql-server-2016-developer image.

  Uses sqlcmd.exe only (always installed with the Database Engine, unlike the
  optional SqlServer/SQLPS PowerShell module) so it has no extra dependencies.
  Data/log file paths are resolved dynamically from the backup's own file list
  and this instance's default data/log directories (SERVERPROPERTY
  InstanceDefaultDataPath/InstanceDefaultLogPath, available since SQL Server
  2016 SP1) - this avoids hard-coding paths that vary by install, and avoids
  guessing the backup's internal logical file names.
#>

$ErrorActionPreference = "Stop"
$logDir = "C:\SQLDemoData"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path "$logDir\restore-adventureworks.log" -Append

function Write-Step {
    param([string]$Message)
    Write-Output "==== $(Get-Date -Format o) - $Message ===="
}

function Wait-ForSqlConnection {
    param([int]$Attempts = 12, [int]$DelaySeconds = 10)
    for ($i = 0; $i -lt $Attempts; $i++) {
        & sqlcmd -S localhost -Q "SET NOCOUNT ON; SELECT 1" *> $null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds $DelaySeconds
    }
    return $false
}

try {
    # Grant the SQL Server Database Engine service account (default instance =
    # the well-known "NT SERVICE\MSSQLSERVER" virtual account on this
    # Marketplace image) read/write access to this folder - without this,
    # RESTORE FILELISTONLY/RESTORE DATABASE fail with "Operating system error
    # 5 (Access is denied)" since the engine runs as its own service account,
    # not as the SYSTEM account this extension script runs under.
    Write-Step "Granting SQL Server service account access to $logDir"
    & icacls $logDir /grant "NT SERVICE\MSSQLSERVER:(OI)(CI)F" /T | Out-Null

    # Windows Server 2016's default .NET TLS setting excludes TLS 1.2, which
    # GitHub's release download endpoint requires.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $bakPath = "$logDir\AdventureWorks2016.bak"
    $bakUrl = "https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2016.bak"

    Write-Step "Downloading AdventureWorks2016.bak from the official Microsoft sample repository"
    $downloadAttempts = 0
    do {
        $downloadAttempts++
        try {
            Invoke-WebRequest -Uri $bakUrl -OutFile $bakPath -UseBasicParsing
            break
        } catch {
            Write-Output "Download attempt $downloadAttempts failed: $_"
            if ($downloadAttempts -ge 3) { throw }
            Start-Sleep -Seconds 15
        }
    } while ($downloadAttempts -lt 3)

    # Give the SQL Server service a little time to finish starting up after
    # VM boot before the first connection attempt (retried, not a fixed sleep).
    Write-Step "Waiting for SQL Server to accept connections"
    if (-not (Wait-ForSqlConnection)) { throw "SQL Server did not become available in time" }

    # This CustomScriptExtension always runs as NT AUTHORITY\SYSTEM, which the
    # Marketplace image's SQL Server instance grants a login to but NOT
    # sysadmin - RESTORE FILELISTONLY/RESTORE DATABASE both require it. Rather
    # than assume any particular admin account has sysadmin, grant it to
    # SYSTEM using Microsoft's own documented recovery procedure (temporarily
    # restart the engine in single-user mode, which treats the first
    # connection as sysadmin): https://learn.microsoft.com/sql/database-engine/configure-windows/scenario-regain-access-to-a-server
    Write-Step "Checking whether NT AUTHORITY\SYSTEM already has sysadmin"
    $isSysadmin = (& sqlcmd -S localhost -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(IS_SRVROLEMEMBER('sysadmin') AS int)" | Select-Object -First 1).Trim()

    if ($isSysadmin -ne "1") {
        Write-Step "Granting NT AUTHORITY\SYSTEM sysadmin via single-user mode"
        $instanceId = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL" -Name "MSSQLSERVER").MSSQLSERVER
        $sqlBinRoot = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\Setup" -Name "SQLBinRoot").SQLBinRoot
        $sqlservrExe = Join-Path $sqlBinRoot "sqlservr.exe"

        Stop-Service -Name "MSSQLSERVER" -Force
        $singleUserProc = Start-Process -FilePath $sqlservrExe -ArgumentList '-m"SQLCMD"' -PassThru -WindowStyle Hidden
        try {
            if (-not (Wait-ForSqlConnection -Attempts 18 -DelaySeconds 5)) {
                throw "SQL Server did not start in single-user mode"
            }
            & sqlcmd -S localhost -Q "ALTER SERVER ROLE sysadmin ADD MEMBER [NT AUTHORITY\SYSTEM]"
            if ($LASTEXITCODE -ne 0) { throw "Failed to grant sysadmin to NT AUTHORITY\SYSTEM" }
        } finally {
            Stop-Process -Id $singleUserProc.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Start-Service -Name "MSSQLSERVER"
        }

        Write-Step "Waiting for SQL Server to accept connections after restart"
        if (-not (Wait-ForSqlConnection)) { throw "SQL Server did not restart normally after granting sysadmin" }
    }

    Write-Step "Resolving default data/log paths and backup file list"
    $dataPath = (& sqlcmd -S localhost -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(260))" | Select-Object -First 1).Trim()
    $logPath = (& sqlcmd -S localhost -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(260))" | Select-Object -First 1).Trim()

    $fileListSql = @"
SET NOCOUNT ON;
IF OBJECT_ID('tempdb..#filelist') IS NOT NULL DROP TABLE #filelist;
CREATE TABLE #filelist (
    LogicalName nvarchar(128), PhysicalName nvarchar(260), Type char(1), FileGroupName nvarchar(128),
    Size numeric(20,0), MaxSize numeric(20,0), FileId bigint, CreateLSN numeric(25,0), DropLSN numeric(25,0),
    UniqueId uniqueidentifier, ReadOnlyLSN numeric(25,0), ReadWriteLSN numeric(25,0), BackupSizeInBytes bigint,
    SourceBlockSize int, FileGroupId int, LogGroupGUID uniqueidentifier, DifferentialBaseLSN numeric(25,0),
    DifferentialBaseGUID uniqueidentifier, IsReadOnly bit, IsPresent bit, TDEThumbprint varbinary(32),
    SnapshotURL nvarchar(360)
);
INSERT INTO #filelist EXEC('RESTORE FILELISTONLY FROM DISK = N''$bakPath''');
SELECT LogicalName + '|' + Type FROM #filelist;
"@
    # Merge stderr into the captured output so SQL errors (e.g. permission
    # issues reading the backup file) are visible in this log instead of
    # silently disappearing, which is what made this failure hard to diagnose
    # the first time.
    $fileListLines = & sqlcmd -S localhost -h -1 -W -Q $fileListSql 2>&1
    $fileListLines | ForEach-Object { Write-Output "sqlcmd: $_" }
    if ($LASTEXITCODE -ne 0) { throw "Failed to read backup file list" }

    $moveClauses = @()
    foreach ($line in $fileListLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\|'
        if ($parts.Count -lt 2) { continue }
        $logicalName = $parts[0].Trim()
        $type = $parts[1].Trim()
        $ext = if ($type -eq "L") { "ldf" } else { "mdf" }
        $targetDir = if ($type -eq "L") { $logPath } else { $dataPath }
        $target = Join-Path $targetDir "$logicalName.$ext"
        $moveClauses += "MOVE N'$logicalName' TO N'$target'"
    }
    if ($moveClauses.Count -eq 0) { throw "Could not determine any files to restore from the backup" }
    $moveSql = $moveClauses -join ", "

    Write-Step "Restoring AdventureWorks2016 database"
    & sqlcmd -S localhost -Q "RESTORE DATABASE [AdventureWorks2016] FROM DISK = N'$bakPath' WITH $moveSql, REPLACE, STATS = 10"
    if ($LASTEXITCODE -ne 0) { throw "RESTORE DATABASE failed with exit code $LASTEXITCODE" }

    Write-Step "AdventureWorks2016 restored successfully"
    Stop-Transcript
    exit 0
} catch {
    Write-Output "RESTORE FAILED: $_"
    Stop-Transcript
    exit 1
}
