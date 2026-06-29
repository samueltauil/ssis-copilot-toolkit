<#
.SYNOPSIS
  Runs `dtexec /Validate /WarnAsError` against a .dtsx file.

.DESCRIPTION
  Single-purpose primitive. Returns a PSCustomObject with the exit code,
  the last lines of dtexec output, and a PASS/FAIL string. The
  ssis-delivery-gate skill (run by ssis-validator) calls this and triages
  any failure via the dtexec-validation-triage skill.

  This script DOES NOT triage, DOES NOT propose fixes, DOES NOT run other
  primitives. By design.

.PARAMETER Package
  Path to the .dtsx to validate.

.PARAMETER DtexecPath
  Optional override for dtexec.exe location. Defaults to the standard SQL
  Server 2025 install path; falls back to PATH lookup.

.EXAMPLE
  .\tools\Test-SsisPackage.ps1 -Package .\templates\ssis-project\Packages\Stg_Customer.dtsx

.NOTES
  Cite: https://learn.microsoft.com/sql/integration-services/packages/dtexec-utility?view=sql-server-ver17
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Package,
    [string] $DtexecPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Package)) {
    throw "Package not found: $Package"
}

# Resolve dtexec
if (-not $DtexecPath) {
    $candidates = @(
        'C:\Program Files\Microsoft SQL Server\170\DTS\Binn\dtexec.exe',
        'C:\Program Files\Microsoft SQL Server\160\DTS\Binn\dtexec.exe',
        'C:\Program Files (x86)\Microsoft SQL Server\170\DTS\Binn\dtexec.exe',
        'C:\Program Files (x86)\Microsoft SQL Server\160\DTS\Binn\dtexec.exe'
    )
    $DtexecPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $DtexecPath) {
        $onPath = Get-Command dtexec.exe -ErrorAction SilentlyContinue
        if ($onPath) { $DtexecPath = $onPath.Source }
    }
}
if (-not $DtexecPath -or -not (Test-Path -LiteralPath $DtexecPath)) {
    throw "Could not locate dtexec.exe. Install SQL Server 2025 Integration Services or pass -DtexecPath."
}

$args = @(
    '/File',     "`"$Package`"",
    '/Validate',
    '/WarnAsError'
)

$output = & $DtexecPath @args 2>&1
$exitCode = $LASTEXITCODE

$result = [PSCustomObject]@{
    Package  = (Resolve-Path -LiteralPath $Package).Path
    ExitCode = $exitCode
    Status   = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    Tail     = ($output | Select-Object -Last 40) -join "`n"
}

# Echo for human readers / VS Code task pane
Write-Host ("dtexec /Validate exit={0} ({1})" -f $exitCode, $result.Status)
if ($exitCode -ne 0) {
    Write-Host "--- last 40 lines ---"
    Write-Host $result.Tail
}

$result
exit $exitCode
