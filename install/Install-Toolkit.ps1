#requires -Version 5.1
<#
.SYNOPSIS
    One-time bootstrap of the SSIS Copilot Toolkit demo environment.

.DESCRIPTION
    Idempotent setup of:
      1. SSISDB catalog (created via SSMS if missing — this script verifies).
      2. Demo databases: CopilotSSIS_Source and CopilotSSIS_Warehouse.
      3. Demo schemas (stg, dim, fact, etl) and audit tables.
      4. Initial AdventureWorks2025 attach verification.

    Re-running this script is safe. It will skip any step whose target already
    exists unless -Force is specified.

.PARAMETER Server
    SQL Server instance. Default '.\SQL2025'.

.PARAMETER Force
    Drop and recreate the demo warehouse database.

.EXAMPLE
    .\install\Install-Toolkit.ps1
    .\install\Install-Toolkit.ps1 -Server '.\SQL2025' -Force
#>
[CmdletBinding()]
param(
    [string]$Server = '.\SQL2025',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { Write-Host "[Install] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "[Install] $Message" -ForegroundColor Green }
function Write-Skip([string]$Message) { Write-Host "[Install] $Message" -ForegroundColor Yellow }

# --- 0. Module check ---------------------------------------------------------

Write-Step 'Checking SqlServer PowerShell module...'
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    throw 'SqlServer PowerShell module not installed. Run: Install-Module SqlServer -Scope CurrentUser'
}
Import-Module SqlServer

# --- 1. Connectivity check ---------------------------------------------------

Write-Step "Verifying connectivity to $Server..."
try {
    Invoke-Sqlcmd -ServerInstance $Server -Database master -Query 'SELECT 1 AS ok' -ErrorAction Stop | Out-Null
    Write-Ok "Connected to $Server."
}
catch {
    throw "Cannot reach $Server. Check service is running and you have rights. Inner: $($_.Exception.Message)"
}

# --- 2. SSISDB check ---------------------------------------------------------

Write-Step 'Verifying SSISDB catalog exists...'
$ssisdb = Invoke-Sqlcmd -ServerInstance $Server -Database master -Query @"
SELECT name FROM sys.databases WHERE name = 'SSISDB';
"@

if (-not $ssisdb) {
    Write-Skip 'SSISDB not found. Create it via SSMS: Integration Services Catalogs -> Create Catalog. Then rerun this script.'
}
else {
    Write-Ok 'SSISDB present.'
}

# --- 3. Demo databases -------------------------------------------------------

foreach ($db in 'CopilotSSIS_Source', 'CopilotSSIS_Warehouse') {
    $exists = Invoke-Sqlcmd -ServerInstance $Server -Database master -Query "SELECT name FROM sys.databases WHERE name = '$db';"
    if ($exists -and -not $Force) {
        Write-Skip "$db already exists. Use -Force to recreate."
        continue
    }
    if ($exists -and $Force) {
        Write-Step "Dropping $db (-Force)..."
        Invoke-Sqlcmd -ServerInstance $Server -Database master -Query "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$db];"
    }
    Write-Step "Creating $db..."
    Invoke-Sqlcmd -ServerInstance $Server -Database master -Query "CREATE DATABASE [$db];"
    Write-Ok "$db created."
}

# --- 4. Apply SQL scripts in order -------------------------------------------

$sqlDir = Join-Path $PSScriptRoot '..\templates\sql' -Resolve -ErrorAction SilentlyContinue
if ($sqlDir) {
    $scripts = Get-ChildItem -Path $sqlDir -Filter '*.sql' | Where-Object { $_.Name -match '^\d{2}-' } | Sort-Object Name
    foreach ($s in $scripts) {
        Write-Step "Applying $($s.Name)..."
        # TODO P4: target DB inferred from script header USE clause. For now, run against master and rely on the script's USE.
        Invoke-Sqlcmd -ServerInstance $Server -Database master -InputFile $s.FullName
        Write-Ok "$($s.Name) applied."
    }
}
else {
    Write-Skip 'templates\sql\ has no numbered scripts yet (P4 will add them).'
}

# --- 5. AdventureWorks2025 verification --------------------------------------

Write-Step 'Verifying AdventureWorks2025 attached...'
$aw = Invoke-Sqlcmd -ServerInstance $Server -Database master -Query "SELECT name FROM sys.databases WHERE name = 'AdventureWorks2025';"
if ($aw) {
    Write-Ok 'AdventureWorks2025 present.'
}
else {
    Write-Skip 'AdventureWorks2025 not attached. Download .bak from https://learn.microsoft.com/sql/samples/adventureworks-install-configure and RESTORE.'
}

Write-Host ''
Write-Ok 'Toolkit bootstrap complete. Next: open Copilot Chat and run /scaffold-new-ssis-project.'
