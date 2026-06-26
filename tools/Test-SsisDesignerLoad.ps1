<#
.SYNOPSIS
  Designer-load round-trip via the managed OM (Application.LoadPackage).

.DESCRIPTION
  Thin wrapper around SsisOmHost.exe verify. The OM call
  (Application.LoadPackage + SaveToXml) requires .NET Framework — it
  cannot be hosted in PowerShell 7 (System.Data.SqlContext is unavailable
  under .NET Core). The C# helper exe runs under .NET Framework 4.8 and
  uses the exact same code path Visual Studio's SSIS designer uses on
  open.

  Used as Step 2 of the ssis-delivery-gate skill.

.PARAMETER Package
  Path to the .dtsx to round-trip.

.EXAMPLE
  .\tools\Test-SsisDesignerLoad.ps1 -Package .\templates\ssis-project\Packages\Stg_Customer.dtsx

.NOTES
  Cite: https://learn.microsoft.com/sql/integration-services/building-packages-programmatically/loading-and-saving-packages?view=sql-server-ver17
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Package
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Package)) {
    throw "Package not found: $Package"
}

$exePath = Join-Path $PSScriptRoot 'lib\SsisOmHost\SsisOmHost.exe'
if (-not (Test-Path -LiteralPath $exePath)) {
    throw "Helper exe not found: $exePath. Run tools\lib\SsisOmHost\Build-SsisOmHost.ps1 first."
}

$absPackage = (Resolve-Path -LiteralPath $Package).Path
$output = & $exePath @('verify', '--package', $absPackage) 2>&1
$exit = $LASTEXITCODE

$status   = if ($exit -eq 0) { 'PASS' } else { 'FAIL' }
$message  = ($output | Out-String).Trim()

$result = [PSCustomObject]@{
    Package  = $absPackage
    Status   = $status
    Message  = $message
    ExitCode = $exit
}

Write-Host ("Application.LoadPackage round-trip: {0}" -f $status)
if ($status -ne 'PASS') {
    Write-Host "--- exe output ---"
    Write-Host $message
}

$result
exit $exit
