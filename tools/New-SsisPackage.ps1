<#
.SYNOPSIS
    Generate an SSIS .dtsx package from a metadata JSON file.

.DESCRIPTION
    Thin wrapper around the C# helper exe (tools/lib/SsisOmHost/SsisOmHost.exe).
    The helper runs under .NET Framework and uses the SSIS managed object model
    (Microsoft.SqlServer.Dts.Runtime / Pipeline) to author a .dtsx package.

    Why a shell-out and not PowerShell? The SSIS pipeline design-time components
    (Source/Destination/DerivedColumn/Lookup) cannot be activated from a
    PowerShell host - the CLR throws on the COM Instantiate() path. A console
    .exe under csc.exe / .NET Framework 4 activates them cleanly.

    This wrapper:
      1. Ensures the helper exe is built (delegates to Build-SsisOmHost.ps1).
      2. Invokes the exe with --metadata / --output.
      3. Surfaces exit code + stderr verbatim.

.PARAMETER Metadata
    Path to the metadata JSON file under templates/metadata/.

.PARAMETER OutputPath
    Where to write the .dtsx. Default: templates/ssis-project/Packages/<packageName>.dtsx
    Resolved by the helper exe when omitted.

.PARAMETER SkipBuild
    Skip the helper-exe rebuild step. Use when iterating on metadata only.

.EXAMPLE
    .\tools\New-SsisPackage.ps1 -Metadata .\templates\metadata\Stg_Customer.metadata.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Metadata,

    [string]$OutputPath,

    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Metadata)) {
    throw "Metadata file not found: $Metadata"
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$hostDir  = Join-Path $repoRoot 'tools\lib\SsisOmHost'
$exePath  = Join-Path $hostDir  'SsisOmHost.exe'
$buildPs1 = Join-Path $hostDir  'Build-SsisOmHost.ps1'

if (-not $SkipBuild) {
    if (-not (Test-Path -LiteralPath $buildPs1)) {
        throw "Build script not found: $buildPs1"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $buildPs1
    if ($LASTEXITCODE -ne 0) { throw "Build-SsisOmHost.ps1 failed (exit $LASTEXITCODE)." }
}

if (-not (Test-Path -LiteralPath $exePath)) {
    throw "Helper exe not found: $exePath. Re-run without -SkipBuild."
}

if (-not $OutputPath) {
    # Flat structure: packages sit alongside .dtproj in templates/ssis-project/.
    $meta = Get-Content -LiteralPath $Metadata -Raw | ConvertFrom-Json
    if (-not $meta.packageName) {
        throw "metadata.packageName missing - cannot infer OutputPath."
    }
    $pkgDir = Join-Path $repoRoot 'templates\ssis-project'
    if (-not (Test-Path -LiteralPath $pkgDir)) {
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
    }
    $OutputPath = Join-Path $pkgDir ("{0}.dtsx" -f $meta.packageName)
}

# Resolve to absolute paths so the helper has no ambiguity about cwd.
# NOTE: Split-Path -LiteralPath is incompatible with -Parent/-Leaf in PS7
# (LiteralPathSet has no part-selector switches). Use [IO.Path] instead.
$absMetadata = (Resolve-Path -LiteralPath $Metadata).Path
$outDir = [System.IO.Path]::GetDirectoryName($OutputPath)
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$absOutput = Join-Path (Resolve-Path -LiteralPath $outDir).Path ([System.IO.Path]::GetFileName($OutputPath))

$argList = @('build', '--metadata', $absMetadata, '--output', $absOutput)
& $exePath $argList
$exit = $LASTEXITCODE
if ($exit -ne 0) {
    throw "SsisOmHost.exe build failed (exit $exit)."
}

Write-Host ("Generated -> {0}" -f $absOutput) -ForegroundColor Green
