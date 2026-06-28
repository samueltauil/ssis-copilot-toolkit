<#
.SYNOPSIS
    Removes all demo assets created by the SSIS Copilot Toolkit installation.

.DESCRIPTION
    Cleans up the demo environment so you can start fresh or uninstall the toolkit.
    
    Removes:
    - CopilotSSIS_Warehouse database (if present)
    - SSISDB Demo folder (project, executions, environments)
    - Generated .dtproj, .conmgr, and .params files from templates/ssis-project
    - Generated .dtsx packages from templates/ssis-project
    - Built SsisOmHost artifacts (.dll, .exe) from tools/lib/SsisOmHost
    
    Preserves:
    - Source code (PowerShell, C#, metadata JSON, SQL DDL)
    - AdventureWorks2025 database
    - .gitkeep files
    - README.md files

.PARAMETER ServerInstance
    SQL Server instance where databases and SSISDB catalog are hosted.
    Defaults to "localhost\SQL2025".

.PARAMETER DropWarehouse
    If specified, drops the CopilotSSIS_Warehouse database.
    Otherwise, only SSISDB content is removed.

.PARAMETER Force
    Skip all confirmation prompts. Use with caution.

.EXAMPLE
    .\tools\Remove-DemoAssets.ps1
    Interactive cleanup with confirmations.

.EXAMPLE
    .\tools\Remove-DemoAssets.ps1 -DropWarehouse -Force
    Non-interactive cleanup that also drops the warehouse database.

.NOTES
    Primitive script — does one thing. Called by @ssis-author when resetting the demo.
    Safe to run multiple times (idempotent).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ServerInstance = 'localhost\SQL2025',
    [switch]$DropWarehouse,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  SSIS Copilot Toolkit — Demo Asset Cleanup" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $Force) {
    Write-Host "This will remove:" -ForegroundColor Yellow
    if ($DropWarehouse) {
        Write-Host "  ❌ CopilotSSIS_Warehouse database" -ForegroundColor Red
    }
    Write-Host "  ❌ SSISDB Demo folder (project, executions, environments)" -ForegroundColor Red
    Write-Host "  ❌ Generated .dtproj, .conmgr, .params files" -ForegroundColor Red
    Write-Host "  ❌ Generated .dtsx packages in templates/ssis-project" -ForegroundColor Red
    Write-Host "  ❌ Built SsisOmHost artifacts (.dll, .exe)" -ForegroundColor Red
    Write-Host ""
    Write-Host "This will preserve:" -ForegroundColor Green
    Write-Host "  ✅ Source code (PowerShell, C#, metadata JSON, SQL DDL)" -ForegroundColor Green
    Write-Host "  ✅ AdventureWorks2025 database" -ForegroundColor Green
    Write-Host "  ✅ All .github customizations (agents, skills, prompts)" -ForegroundColor Green
    Write-Host ""
    
    $confirm = Read-Host "Continue? (yes/no)"
    if ($confirm -ne 'yes') {
        Write-Host "Cancelled." -ForegroundColor Gray
        return
    }
    Write-Host ""
}

$removedCount = 0

# ---------------------------------------------------------------------------
# 1. Drop CopilotSSIS_Warehouse database (optional)
# ---------------------------------------------------------------------------

if ($DropWarehouse) {
    Write-Host "[1/5] Checking CopilotSSIS_Warehouse database..." -ForegroundColor Cyan
    
    try {
        Import-Module SqlServer -ErrorAction Stop
        
        $checkDbQuery = "SELECT DB_ID('CopilotSSIS_Warehouse') AS DbId"
        $dbExists = (Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $checkDbQuery -TrustServerCertificate).DbId -ne [DBNull]::Value
        
        if ($dbExists) {
            Write-Host "  Dropping CopilotSSIS_Warehouse..." -ForegroundColor Yellow
            
            $dropQuery = @"
USE master;
GO
IF DB_ID('CopilotSSIS_Warehouse') IS NOT NULL
BEGIN
    ALTER DATABASE CopilotSSIS_Warehouse SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE CopilotSSIS_Warehouse;
END
"@
            Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $dropQuery -TrustServerCertificate
            Write-Host "  ✅ CopilotSSIS_Warehouse dropped" -ForegroundColor Green
            $removedCount++
        } else {
            Write-Host "  ℹ️  CopilotSSIS_Warehouse not found (already removed)" -ForegroundColor Gray
        }
    } catch {
        Write-Warning "Failed to drop warehouse database: $_"
    }
    Write-Host ""
} else {
    Write-Host "[1/5] Skipping warehouse database (use -DropWarehouse to remove)" -ForegroundColor Gray
    Write-Host ""
}

# ---------------------------------------------------------------------------
# 2. Remove SSISDB Demo folder
# ---------------------------------------------------------------------------

Write-Host "[2/5] Checking SSISDB Demo folder..." -ForegroundColor Cyan

try {
    Import-Module SqlServer -ErrorAction Stop
    
    $checkFolderQuery = @"
SELECT folder_id 
FROM SSISDB.catalog.folders 
WHERE name = 'Demo'
"@
    
    $folderExists = $null -ne (Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $checkFolderQuery -Database SSISDB -TrustServerCertificate -ErrorAction SilentlyContinue)
    
    if ($folderExists) {
        Write-Host "  Removing Demo folder from SSISDB..." -ForegroundColor Yellow
        
        $dropFolderQuery = @"
DECLARE @folder_id BIGINT = (SELECT folder_id FROM SSISDB.catalog.folders WHERE name = 'Demo');
IF @folder_id IS NOT NULL
BEGIN
    EXEC SSISDB.catalog.delete_folder @folder_name = N'Demo';
END
"@
        Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $dropFolderQuery -Database SSISDB -TrustServerCertificate
        Write-Host "  ✅ Demo folder removed from SSISDB" -ForegroundColor Green
        $removedCount++
    } else {
        Write-Host "  ℹ️  Demo folder not found in SSISDB (already removed)" -ForegroundColor Gray
    }
} catch {
    Write-Warning "Failed to remove SSISDB folder: $_"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 3. Remove generated SSIS project files
# ---------------------------------------------------------------------------

Write-Host "[3/5] Removing generated SSIS project files..." -ForegroundColor Cyan

$projectDir = Join-Path $repoRoot 'templates\ssis-project'
$docsDir = Join-Path $repoRoot 'templates\docs'
$filesToRemove = @(
    (Join-Path $projectDir '*.dtproj')
    (Join-Path $projectDir '*.dtproj.user')
    (Join-Path $projectDir '*.database')
    (Join-Path $projectDir 'Project.params')
    (Join-Path $projectDir '*.conmgr')
    (Join-Path $projectDir 'ConnectionManagers\*.conmgr')
    (Join-Path $projectDir '*.dtsx')
)

# Also remove generated documentation (keep README.md)
$generatedDocs = Get-ChildItem -Path $docsDir -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'README.md' }
foreach ($doc in $generatedDocs) {
    Write-Host "  Removing docs/$($doc.Name)..." -ForegroundColor Yellow
    Remove-Item $doc.FullName -Force
    $removedCount++
}

foreach ($pattern in $filesToRemove) {
    $files = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        Write-Host "  Removing $($file.Name)..." -ForegroundColor Yellow
        Remove-Item $file.FullName -Force
        $removedCount++
    }
}

if ($removedCount -eq 0) {
    Write-Host "  ℹ️  No generated project files found (already removed)" -ForegroundColor Gray
}
Write-Host ""

# ---------------------------------------------------------------------------
# 4. Remove built SsisOmHost artifacts
# ---------------------------------------------------------------------------

Write-Host "[4/5] Removing built SsisOmHost artifacts..." -ForegroundColor Cyan

$hostDir = Join-Path $repoRoot 'tools\lib\SsisOmHost'
$artifactPatterns = @('*.dll', '*.exe', '*.pdb', '*.deps.json', '*.runtimeconfig.json')

$hostRemovedCount = 0
foreach ($pattern in $artifactPatterns) {
    $artifacts = Get-ChildItem -Path $hostDir -Filter $pattern -ErrorAction SilentlyContinue
    foreach ($artifact in $artifacts) {
        if ($artifact.Name -notin @('Build-SsisOmHost.ps1')) {
            Write-Host "  Removing $($artifact.Name)..." -ForegroundColor Yellow
            Remove-Item $artifact.FullName -Force
            $hostRemovedCount++
        }
    }
}

if ($hostRemovedCount -gt 0) {
    Write-Host "  ✅ Removed $hostRemovedCount artifact(s)" -ForegroundColor Green
} else {
    Write-Host "  ℹ️  No artifacts found (already removed)" -ForegroundColor Gray
}
Write-Host ""

# ---------------------------------------------------------------------------
# 5. Remove bin/ directory from project
# ---------------------------------------------------------------------------

Write-Host "[5/5] Removing bin/, obj/, .vs/ directories..." -ForegroundColor Cyan

$dirsToRemove = @('bin', 'obj', '.vs')
foreach ($dirName in $dirsToRemove) {
    $dirPath = Join-Path $projectDir $dirName
    if (Test-Path $dirPath) {
        Write-Host "  Removing $dirName/..." -ForegroundColor Yellow
        Remove-Item $dirPath -Recurse -Force
        Write-Host "  ✅ $dirName/ removed" -ForegroundColor Green
    }
}
if (-not ($dirsToRemove | Where-Object { Test-Path (Join-Path $projectDir $_) })) {
    Write-Host "  ℹ️  No build directories found (already removed)" -ForegroundColor Gray
}
Write-Host ""

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Cleanup complete!" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "To rebuild the demo:" -ForegroundColor Cyan
Write-Host "  1. Run: .\install\Install-Toolkit.ps1" -ForegroundColor Gray
Write-Host "  2. Run: .\tools\New-SsisProject.ps1" -ForegroundColor Gray
Write-Host "  3. Regenerate packages from metadata JSON" -ForegroundColor Gray
Write-Host ""
