<#
.SYNOPSIS
    Install the SSIS Copilot Toolkit overlay into an existing repository.

.DESCRIPTION
    Brownfield onboarding for the SSIS Copilot Toolkit. Drops the Copilot
    customization surface (.github/agents, .github/skills, .github/prompts,
    .github/instructions, copilot-instructions.md), the PowerShell primitives
    (tools/), and the round-trip invariants (.gitattributes, .gitignore block)
    into a target repository. Demo content — AdventureWorks SQL, sample SSIS
    project, engineering plan — is never copied.

    Reads install/overlay.manifest.psd1 from the source toolkit for the file
    list, so this script is just orchestration. Same manifest drives the
    template-cleanup workflow.

    Re-running upgrades the overlay: managed blocks in AGENTS.md and .gitignore
    are replaced in place rather than duplicated, and a version stamp file is
    written to .copilot-ssis-toolkit-version.

.PARAMETER RepoPath
    The path of the target repository's working tree. Defaults to the current
    directory. Must be an existing directory.

.PARAMETER SourcePath
    The path of the SSIS Copilot Toolkit source. Defaults to the script's
    parent directory (so running install\Add-CopilotSsisToolkit.ps1 from a
    clone of the toolkit Just Works). Override when running the script after
    fetching it standalone via iex.

.PARAMETER SourceUri
    HTTPS URL of the toolkit's GitHub raw root, used when SourcePath is not
    available locally. The script downloads the manifest and overlay files
    from this URL. Defaults to the official repo's main branch.

.PARAMETER Mode
    Conflict-resolution mode for file collisions:
      Skip      — leave existing target files untouched (default; safest)
      Overwrite — replace existing target files unconditionally
    AGENTS.md and .gitignore are always merged via managed blocks regardless
    of Mode; their existing content is preserved.

.PARAMETER WhatIf
    Show the actions the installer would take without making changes.

.EXAMPLE
    cd C:\source\my-existing-ssis-repo
    & C:\source\ssis-copilot-toolkit\install\Add-CopilotSsisToolkit.ps1
    # Installs the overlay into the current directory in Skip mode.

.EXAMPLE
    # One-liner from anywhere (requires the published toolkit repo)
    iex (irm https://raw.githubusercontent.com/<owner>/<repo>/main/install/Add-CopilotSsisToolkit.ps1)

.NOTES
    The toolkit's runtime primitives (Test-SsisPackage, Build-SsisOmHost, etc.)
    require Windows + SQL Server tools + .NET Framework 4.x because the SSIS
    managed object model and dtexec are Windows-only. This installer therefore
    targets Windows / Windows PowerShell 5.1 / pwsh 7+; Linux is not supported.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepoPath = (Get-Location).Path,
    [string]$SourcePath = $(Split-Path -Parent (Split-Path -Parent $PSCommandPath)),
    [string]$SourceUri = 'https://raw.githubusercontent.com/<owner>/<repo>/main',
    [ValidateSet('Skip', 'Overwrite')]
    [string]$Mode = 'Skip'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Platform gate — toolkit runtime requires Windows; refuse to install elsewhere
# so adopters don't get a half-working setup.
# ---------------------------------------------------------------------------
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    # Some pwsh builds on Windows don't define $IsWindows in older versions;
    # double-check via PSVersionTable.Platform.
    if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
        throw "The SSIS Copilot Toolkit targets Windows only. dtexec and the SSIS managed object model are Windows-native. Detected platform: $($PSVersionTable.Platform)."
    }
}

# ---------------------------------------------------------------------------
# Resolve source — local clone preferred; fall back to fetching the manifest
# from $SourceUri when running standalone via iex.
# ---------------------------------------------------------------------------
function Resolve-Source {
    param([string]$LocalPath, [string]$RemoteUri)

    $manifestRel = 'install/overlay.manifest.psd1'

    if ($LocalPath -and (Test-Path -LiteralPath (Join-Path $LocalPath $manifestRel))) {
        return [pscustomobject]@{
            Kind = 'Local'
            Root = (Resolve-Path -LiteralPath $LocalPath).Path
        }
    }

    # Remote — download manifest, stage overlay files to a temp dir on demand.
    Write-Host "Source clone not found at '$LocalPath'. Fetching manifest from $RemoteUri ..."
    $tempRoot = Join-Path $env:TEMP "ssis-copilot-toolkit-$(Get-Random)"
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tempRoot 'install') -Force | Out-Null

    $manifestLocal = Join-Path $tempRoot $manifestRel
    Invoke-WebRequest -Uri "$RemoteUri/$manifestRel" -OutFile $manifestLocal -UseBasicParsing

    return [pscustomobject]@{
        Kind      = 'Remote'
        Root      = $tempRoot
        RemoteUri = $RemoteUri
    }
}

# ---------------------------------------------------------------------------
# Lazily fetch a single overlay file from the remote, caching to $tempRoot.
# ---------------------------------------------------------------------------
function Get-OverlayPath {
    param(
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] [string]$RelativePath
    )

    $local = Join-Path $Source.Root $RelativePath
    if ($Source.Kind -eq 'Local') {
        return $local
    }

    if (-not (Test-Path -LiteralPath $local)) {
        $parent = Split-Path -Parent $local
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $url = "$($Source.RemoteUri)/$RelativePath"
        Invoke-WebRequest -Uri $url -OutFile $local -UseBasicParsing
    }
    return $local
}

# ---------------------------------------------------------------------------
# Block management — used for AGENTS.md and .gitignore, where the overlay
# appends a marker-delimited block rather than overwriting.
# ---------------------------------------------------------------------------
function Set-ManagedBlock {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [string]$BlockText,
        [Parameter(Mandatory)] [string]$BeginMarker,
        [Parameter(Mandatory)] [string]$EndMarker
    )

    $existing = ''
    if (Test-Path -LiteralPath $FilePath) {
        $existing = Get-Content -LiteralPath $FilePath -Raw
        if ($null -eq $existing) { $existing = '' }
    }

    # Pattern matches the existing managed block (including markers). Single-line
    # mode so `.` spans newlines.
    $pattern = "(?s)\r?\n?$([regex]::Escape($BeginMarker)).*?$([regex]::Escape($EndMarker))\r?\n?"

    if ($existing -match $pattern) {
        $updated = [regex]::Replace($existing, $pattern, "`n$BlockText`n")
        $verb = 'Updated'
    }
    else {
        $separator = if ($existing -and -not $existing.EndsWith("`n")) { "`n`n" } else { "`n" }
        $updated = "$existing$separator$BlockText`n"
        $verb = 'Appended to'
    }

    if ($PSCmdlet.ShouldProcess($FilePath, "$verb managed block")) {
        $parent = Split-Path -Parent $FilePath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Set-Content -LiteralPath $FilePath -Value $updated -NoNewline -Encoding UTF8
        Write-Host "  $verb managed block: $FilePath"
    }
}

# ---------------------------------------------------------------------------
# Apply a single manifest entry.
# ---------------------------------------------------------------------------
function Invoke-OverlayEntry {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] [string]$TargetRoot,
        [Parameter(Mandatory)] [string]$Mode,
        [Parameter(Mandatory)] $Manifest
    )

    $rel = $Entry.Path
    $action = $Entry.Action
    $targetPath = Join-Path $TargetRoot $rel

    switch ($action) {
        'Copy' {
            $sourcePath = Get-OverlayPath -Source $Source -RelativePath $rel
            Copy-OverlayFile -SourceFile $sourcePath -TargetFile $targetPath -Mode 'Overwrite'
        }
        'CopyIfMissing' {
            if (Test-Path -LiteralPath $targetPath) {
                Write-Host "  Skip (exists): $rel"
                return
            }
            $sourcePath = Get-OverlayPath -Source $Source -RelativePath $rel
            Copy-OverlayFile -SourceFile $sourcePath -TargetFile $targetPath -Mode 'Overwrite'
        }
        'CopyDir' {
            Copy-OverlayDir -RelativeDir $rel -Source $Source -TargetRoot $TargetRoot -Mode $Mode
        }
        'AppendBlock' {
            $blockKey = switch ($rel) {
                'AGENTS.md'  { 'AgentsMdBlock' }
                '.gitignore' { 'GitignoreBlock' }
                default      { $null }
            }
            if (-not $blockKey) {
                throw "AppendBlock action for unknown path: $rel"
            }
            $blockText = $Manifest.$blockKey
            $lines = $blockText -split "`r?`n"
            $beginMarker = $lines[0]
            $endMarker = $lines[-1]
            Set-ManagedBlock -FilePath $targetPath -BlockText $blockText `
                -BeginMarker $beginMarker -EndMarker $endMarker
        }
        default {
            throw "Unknown overlay action: $action (entry: $rel)"
        }
    }
}

function Copy-OverlayFile {
    param([string]$SourceFile, [string]$TargetFile, [string]$Mode)

    if (-not (Test-Path -LiteralPath $SourceFile)) {
        throw "Overlay source file missing: $SourceFile"
    }

    if ((Test-Path -LiteralPath $TargetFile) -and $Mode -eq 'Skip') {
        Write-Host "  Skip (exists, Mode=Skip): $TargetFile"
        return
    }

    if ($PSCmdlet.ShouldProcess($TargetFile, 'Copy overlay file')) {
        $parent = Split-Path -Parent $TargetFile
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $SourceFile -Destination $TargetFile -Force
        Write-Host "  Wrote: $TargetFile"
    }
}

function Copy-OverlayDir {
    param([string]$RelativeDir, $Source, [string]$TargetRoot, [string]$Mode)

    if ($Source.Kind -eq 'Remote') {
        # Bulk directory copy from a raw URL isn't trivial — GitHub's raw endpoint
        # serves files, not directory listings. For now, require a local clone for
        # CopyDir entries and surface a clear error.
        throw "CopyDir entries (e.g. $RelativeDir) require a local toolkit clone. Run from a cloned working tree or pass -SourcePath."
    }

    $sourceDir = Join-Path $Source.Root $RelativeDir
    if (-not (Test-Path -LiteralPath $sourceDir)) {
        throw "Overlay source directory missing: $sourceDir"
    }

    $files = Get-ChildItem -LiteralPath $sourceDir -Recurse -File
    foreach ($file in $files) {
        $sub = $file.FullName.Substring($sourceDir.Length).TrimStart('\', '/')
        $relPath = (Join-Path $RelativeDir $sub) -replace '\\', '/'
        $targetPath = Join-Path $TargetRoot $relPath
        Copy-OverlayFile -SourceFile $file.FullName -TargetFile $targetPath -Mode $Mode
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
Write-Host ""
Write-Host "SSIS Copilot Toolkit — brownfield installer"
Write-Host "  Target repo : $RepoPath"
Write-Host "  Mode        : $Mode"
Write-Host ""

$source = Resolve-Source -LocalPath $SourcePath -RemoteUri $SourceUri
Write-Host "  Source kind : $($source.Kind)"
Write-Host "  Source root : $($source.Root)"
Write-Host ""

$manifestPath = Join-Path $source.Root 'install/overlay.manifest.psd1'
$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Write-Host "Loaded manifest v$($manifest.Version) — $($manifest.Overlay.Count) overlay entries."
Write-Host ""

foreach ($entry in $manifest.Overlay) {
    Invoke-OverlayEntry -Entry $entry -Source $source -TargetRoot $RepoPath `
        -Mode $Mode -Manifest $manifest
}

# Version stamp — lets future installer runs detect upgrades.
$stamp = Join-Path $RepoPath '.copilot-ssis-toolkit-version'
$stampContent = @"
$($manifest.Version)
# SSIS Copilot Toolkit overlay version. Managed by install/Add-CopilotSsisToolkit.ps1.
# Source: $SourceUri
# Installed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ssK')
"@
if ($PSCmdlet.ShouldProcess($stamp, 'Write version stamp')) {
    Set-Content -LiteralPath $stamp -Value $stampContent -Encoding UTF8
    Write-Host ""
    Write-Host "Wrote version stamp: $stamp"
}

# Clean up remote staging
if ($source.Kind -eq 'Remote') {
    Remove-Item -LiteralPath $source.Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Done."
Write-Host "Next steps:"
Write-Host "  1. Review the appended block in AGENTS.md and update <owner>/<repo> placeholders."
Write-Host "  2. Build the managed-OM host:  .\tools\lib\SsisOmHost\Build-SsisOmHost.ps1"
Write-Host "  3. Open the repo in Visual Studio 2026 (18.4+) or VS Code with GitHub Copilot Chat."
Write-Host "  4. From Copilot Chat, select 'ssis-author' from the agent picker to start authoring packages."
