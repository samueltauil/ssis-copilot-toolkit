# Build-SsisOmHost.ps1 - compiles tools/lib/SsisOmHost/*.cs into SsisOmHost.exe using csc.exe
# from .NET Framework 4.x. No MSBuild dependency. Run from any host (pwsh or powershell).
#
# Output: tools/lib/SsisOmHost/SsisOmHost.exe (alongside the .cs sources).
#
# The reason for shelling out to a .NET Framework exe: PowerShell host cannot activate
# SSIS pipeline design-time components - IDTSDesigntimeComponent100.ProvideComponentProperties()
# always fails with TYPE_E_ELEMENTNOTFOUND in powershell.exe. A plain .NET Framework console
# exe activates them correctly. See /memories/repo/ssis-toolkit-locked-decisions.md.

[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir  = $here
$exePath = Join-Path $srcDir 'SsisOmHost.exe'

# Skip rebuild if exe is newer than every .cs (unless -Force).
if (-not $Force -and (Test-Path $exePath)) {
    $exeStamp = (Get-Item $exePath).LastWriteTimeUtc
    $newer = Get-ChildItem -Path $srcDir -Filter *.cs -Recurse |
        Where-Object { $_.LastWriteTimeUtc -gt $exeStamp } | Select-Object -First 1
    if (-not $newer) {
        Write-Host "SsisOmHost.exe up to date." -ForegroundColor DarkGray
        return
    }
}

$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
    throw "csc.exe not found at $csc. .NET Framework 4.x is required to build SsisOmHost."
}

$mdtsDll  = 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Microsoft.SqlServer.ManagedDTS\v4.0_17.0.0.0__89845dcd8080cc91\Microsoft.SqlServer.ManagedDTS.dll'
$pwrapDll = 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Microsoft.SqlServer.DTSPipelineWrap\v4.0_17.0.0.0__89845dcd8080cc91\Microsoft.SQLServer.DTSPipelineWrap.dll'
$rwrapDll = 'C:\Windows\Microsoft.NET\assembly\GAC_64\Microsoft.SqlServer.DTSRuntimeWrap\v4.0_17.0.0.0__89845dcd8080cc91\Microsoft.SqlServer.DTSRuntimeWrap.dll'

foreach ($dll in @($mdtsDll, $pwrapDll, $rwrapDll)) {
    if (-not (Test-Path $dll)) {
        throw ("Required SSIS assembly missing from GAC: " + $dll + ". Install SQL Server 2025 Integration Services Shared.")
    }
}

$sources = Get-ChildItem -Path $srcDir -Filter *.cs -Recurse |
    Where-Object { -not $_.Name.StartsWith('_') } |
    ForEach-Object { $_.FullName }
if ($sources.Count -eq 0) { throw "No .cs source files under $srcDir." }

$cscArgs = @(
    '/nologo'
    '/platform:x64'
    '/target:exe'
    "/out:$exePath"
    "/r:$mdtsDll"
    "/r:$pwrapDll"
    "/r:$rwrapDll"
    '/r:System.Web.Extensions.dll'   # JavaScriptSerializer
    '/r:System.Data.dll'             # SqlClient for Lookup reference-schema introspection
)
$cscArgs += $sources

Write-Host "Compiling SsisOmHost.exe..." -ForegroundColor Cyan
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) {
    throw "csc.exe failed with exit code $LASTEXITCODE."
}
Write-Host "OK: $exePath" -ForegroundColor Green
