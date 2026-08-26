<#
.SYNOPSIS
    Install the SSIS Copilot Toolkit overlay into an existing repository.

.DESCRIPTION
    Brownfield onboarding for the SSIS Copilot Toolkit. Drops the Copilot
    customization surface (.github/agents, .github/skills, .github/prompts,
    .github/instructions, copilot-instructions.md), the PowerShell primitives
    (tools/), and the round-trip invariants (.gitattributes, .gitignore block)
    into a target repository. Demo content - AdventureWorks SQL, sample SSIS
    project, engineering plan - is never copied.

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
    clone of the toolkit Just Works). When the script is fetched standalone
    via iex there is no script path, so the source is downloaded instead -
    see SourceRepo / SourceRef. Override via the SSIS_TOOLKIT_SOURCE_PATH
    environment variable to point the iex path at an existing clone.

.PARAMETER SourceRepo
    GitHub "owner/repo" of the toolkit, used when no local clone is available.
    Defaults to the official toolkit repository. Override via the
    SSIS_TOOLKIT_SOURCE_REPO environment variable when running via iex.

.PARAMETER SourceRef
    Branch, tag, or commit SHA to install from. Defaults to 'main'. Override
    via the SSIS_TOOLKIT_SOURCE_REF environment variable when running via iex.

.PARAMETER Mode
    Conflict-resolution mode for file collisions:
      Skip      - leave existing target files untouched (default; safest)
      Overwrite - replace existing target files unconditionally
    AGENTS.md and .gitignore are always merged via managed blocks regardless
    of Mode; their existing content is preserved. Override via the
    SSIS_TOOLKIT_MODE environment variable when running via iex.

.PARAMETER WhatIf
    Show the actions the installer would take without making changes.

.EXAMPLE
    cd C:\source\my-existing-ssis-repo
    & C:\source\ssis-copilot-toolkit\install\Add-CopilotSsisToolkit.ps1
    # Installs the overlay into the current directory in Skip mode.

.EXAMPLE
    # One-liner from anywhere (downloads the toolkit source archive)
    iex (irm https://raw.githubusercontent.com/samueltauil/ssis-copilot-toolkit/main/install/Add-CopilotSsisToolkit.ps1)

.EXAMPLE
    # Same one-liner, overwriting existing overlay files
    $env:SSIS_TOOLKIT_MODE = 'Overwrite'
    iex (irm https://raw.githubusercontent.com/samueltauil/ssis-copilot-toolkit/main/install/Add-CopilotSsisToolkit.ps1)

.NOTES
    The toolkit's runtime primitives (Test-SsisPackage, Build-SsisOmHost, etc.)
    require Windows + SQL Server tools + .NET Framework 4.x because the SSIS
    managed object model and dtexec are Windows-only. This installer therefore
    targets Windows / Windows PowerShell 5.1 / pwsh 7+; Linux is not supported.

    This script must behave identically in three hosts: a normally-invoked
    .ps1, `iex (irm ...)` under pwsh 7, and `iex (irm ...)` under Windows
    PowerShell 5.1. Under iex there is no $PSCommandPath and no $PSCmdlet, and
    5.1 defines neither $IsWindows nor $PSVersionTable.Platform - combined with
    Set-StrictMode that turns a bare `$IsWindows` reference into a hard failure.
    Every default is therefore resolved defensively in the bootstrap below
    rather than in the param block, and parameters accept no positional
    defaults that depend on the host.

    Keep this file pure ASCII. It carries no BOM (so `iex (irm ...)` sees clean
    text), which means Windows PowerShell 5.1 decodes it as ANSI when it is run
    as a .ps1. A UTF-8 em dash then arrives as three cp1252 characters, one of
    which is a smart quote that PowerShell honours as a string delimiter -
    silently breaking the parse. Every other file in the repo may use em
    dashes; this bootstrap may not.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepoPath,
    [string]$SourcePath,
    [string]$SourceRepo,
    [string]$SourceRef,
    # Deliberately no [ValidateSet]. Under `iex` the param block is evaluated
    # against a pre-existing empty variable, and attaching a ValidateSet to it
    # throws "the attribute cannot be added because variable Mode ... would no
    # longer be valid". Mode is validated explicitly in the bootstrap instead.
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Bootstrap - resolve host-dependent state without touching variables that may
# not exist. Get-Variable -ErrorAction SilentlyContinue is the only strict-mode
# safe way to probe for an automatic variable. No -Scope: the lookup must walk
# the scope chain so a helper can see the script's own automatic variables.
# ---------------------------------------------------------------------------
function Get-OptionalVariableValue {
    param([Parameter(Mandatory)] [string]$Name)

    $var = Get-Variable -Name $Name -ErrorAction SilentlyContinue
    if ($var) { return $var.Value }
    return $null
}

# $PSCmdlet exists only when this file is invoked as a script/function. Capture
# it here at script scope; ShouldProcess is routed through Test-ShouldProcess so
# the iex path (where it is absent) still honours -WhatIf via $WhatIfPreference.
$script:Cmdlet = $null
$cmdletVar = Get-Variable -Name 'PSCmdlet' -Scope 0 -ErrorAction SilentlyContinue
if ($cmdletVar) { $script:Cmdlet = $cmdletVar.Value }

function Test-ShouldProcess {
    param([Parameter(Mandatory)] [string]$Target, [Parameter(Mandatory)] [string]$Action)

    if ($script:Cmdlet) { return $script:Cmdlet.ShouldProcess($Target, $Action) }
    if ($WhatIfPreference) {
        Write-Host "  What if: $Action`: $Target"
        return $false
    }
    return $true
}

# UTF-8 without BOM. Windows PowerShell's -Encoding UTF8 emits a BOM, which
# corrupts the first pattern of a .gitignore and dirties every rewrite of
# AGENTS.md, so all text output goes through here instead of Set-Content.
function Write-TextFile {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [AllowEmptyString()] [string]$Content)

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
    if ($env:SSIS_TOOLKIT_REPO_PATH) { $RepoPath = $env:SSIS_TOOLKIT_REPO_PATH }
    else { $RepoPath = (Get-Location).Path }
}

if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    if ($env:SSIS_TOOLKIT_SOURCE_PATH) {
        $SourcePath = $env:SSIS_TOOLKIT_SOURCE_PATH
    }
    else {
        # Empty string under iex; a real path when invoked as install\Add-CopilotSsisToolkit.ps1.
        $commandPath = Get-OptionalVariableValue -Name 'PSCommandPath'
        if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
            $SourcePath = Split-Path -Parent (Split-Path -Parent $commandPath)
        }
    }
}

if ([string]::IsNullOrWhiteSpace($SourceRepo)) {
    if ($env:SSIS_TOOLKIT_SOURCE_REPO) { $SourceRepo = $env:SSIS_TOOLKIT_SOURCE_REPO }
    else { $SourceRepo = 'samueltauil/ssis-copilot-toolkit' }
}

if ([string]::IsNullOrWhiteSpace($SourceRef)) {
    if ($env:SSIS_TOOLKIT_SOURCE_REF) { $SourceRef = $env:SSIS_TOOLKIT_SOURCE_REF }
    else { $SourceRef = 'main' }
}

# Mode is validated here rather than with a [ValidateSet] attribute; see the
# param block for why that attribute cannot survive the iex path.
$modeCandidate = $Mode
if ([string]::IsNullOrWhiteSpace($modeCandidate)) { $modeCandidate = $env:SSIS_TOOLKIT_MODE }
if ([string]::IsNullOrWhiteSpace($modeCandidate)) { $modeCandidate = 'Skip' }
if (@('Skip', 'Overwrite') -notcontains $modeCandidate) {
    throw "Invalid Mode '$modeCandidate'. Expected 'Skip' or 'Overwrite'."
}
$Mode = $modeCandidate

# ---------------------------------------------------------------------------
# Platform gate - toolkit runtime requires Windows; refuse to install elsewhere
# so adopters don't get a half-working setup. Windows PowerShell (Desktop) is
# Windows by definition and defines none of the $Is* variables.
# ---------------------------------------------------------------------------
$onWindows = $true
if ($PSVersionTable.PSEdition -eq 'Core') {
    $isWindowsValue = Get-OptionalVariableValue -Name 'IsWindows'
    if ($null -ne $isWindowsValue) {
        $onWindows = [bool]$isWindowsValue
    }
    elseif ($PSVersionTable.ContainsKey('Platform')) {
        $onWindows = ($PSVersionTable.Platform -eq 'Win32NT')
    }
}
if (-not $onWindows) {
    throw "The SSIS Copilot Toolkit targets Windows only. dtexec and the SSIS managed object model are Windows-native."
}

# ---------------------------------------------------------------------------
# Resolve source - local clone preferred; otherwise download and stage the
# toolkit source archive.
#
# Per-file raw.githubusercontent.com downloads cannot satisfy the manifest's
# CopyDir entries (.github/agents, .github/skills, tools/lib/patterns, ...)
# because the raw endpoint serves files, not directory listings. Staging the
# whole archive makes the remote path behave exactly like a local clone, which
# is what `iex (irm ...)` needs to work end to end.
# ---------------------------------------------------------------------------
function Resolve-Source {
    param([string]$LocalPath, [string]$Repo, [string]$Ref)

    $manifestRel = 'install/overlay.manifest.psd1'

    if (-not [string]::IsNullOrWhiteSpace($LocalPath) -and
        (Test-Path -LiteralPath (Join-Path $LocalPath $manifestRel))) {
        $resolved = (Resolve-Path -LiteralPath $LocalPath).Path
        return [pscustomobject]@{
            Kind        = 'LocalClone'
            Root        = $resolved
            Origin      = $resolved
            Staged      = $false
            StagingRoot = $null
        }
    }

    $archiveUri = "https://codeload.github.com/$Repo/zip/$Ref"
    Write-Host "No local toolkit clone found. Downloading $Repo@$Ref ..."

    # Windows PowerShell 5.1 still negotiates TLS 1.0 by default on some hosts;
    # GitHub requires 1.2+.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Verbose "Could not raise TLS version: $($_.Exception.Message)"
    }

    $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ssis-copilot-toolkit-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    $zipPath = Join-Path $stagingRoot 'toolkit.zip'
    try {
        Invoke-WebRequest -Uri $archiveUri -OutFile $zipPath -UseBasicParsing
    }
    catch {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw "Failed to download the toolkit archive from $archiveUri - $($_.Exception.Message). Check the repo/ref (SSIS_TOOLKIT_SOURCE_REPO / SSIS_TOOLKIT_SOURCE_REF) or clone the toolkit and pass -SourcePath."
    }

    $extractRoot = Join-Path $stagingRoot 'extracted'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

    # GitHub archives nest the tree under a single "<repo>-<ref>" directory.
    $inner = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1
    if (-not $inner -or -not (Test-Path -LiteralPath (Join-Path $inner.FullName $manifestRel))) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw "Downloaded archive from $archiveUri does not contain $manifestRel."
    }

    return [pscustomobject]@{
        Kind        = 'Downloaded'
        Root        = $inner.FullName
        Origin      = "$Repo@$Ref"
        Staged      = $true
        StagingRoot = $stagingRoot
    }
}

# ---------------------------------------------------------------------------
# Locate a single overlay file within the resolved source tree.
# ---------------------------------------------------------------------------
function Get-OverlayPath {
    param(
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] [string]$RelativePath
    )

    $path = Join-Path $Source.Root $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Overlay source file missing from $($Source.Origin): $RelativePath"
    }
    return $path
}

# ---------------------------------------------------------------------------
# Block management - used for AGENTS.md and .gitignore, where the overlay
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

    if (Test-ShouldProcess -Target $FilePath -Action "$verb managed block") {
        Write-TextFile -Path $FilePath -Content $updated
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
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] [string]$SourceRepo
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
            $blockText = $Manifest.$blockKey -replace '<owner>/<repo>', $SourceRepo
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

    if (Test-ShouldProcess -Target $TargetFile -Action 'Copy overlay file') {
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

    $sourceDir = Join-Path $Source.Root $RelativeDir
    if (-not (Test-Path -LiteralPath $sourceDir)) {
        throw "Overlay source directory missing from $($Source.Origin): $RelativeDir"
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
Write-Host "SSIS Copilot Toolkit - brownfield installer"
Write-Host "  Target repo : $RepoPath"
Write-Host "  Mode        : $Mode"
Write-Host "  Host        : PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Write-Host ""

$source = Resolve-Source -LocalPath $SourcePath -Repo $SourceRepo -Ref $SourceRef
Write-Host "  Source kind : $($source.Kind)"
Write-Host "  Source root : $($source.Root)"
Write-Host ""

try {
    $manifestPath = Join-Path $source.Root 'install/overlay.manifest.psd1'
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    Write-Host "Loaded manifest v$($manifest.Version) - $($manifest.Overlay.Count) overlay entries."
    Write-Host ""

    foreach ($entry in $manifest.Overlay) {
        Invoke-OverlayEntry -Entry $entry -Source $source -TargetRoot $RepoPath `
            -Mode $Mode -Manifest $manifest -SourceRepo $SourceRepo
    }

    # Version stamp - lets future installer runs detect upgrades.
    $stamp = Join-Path $RepoPath '.copilot-ssis-toolkit-version'
    $stampContent = @"
$($manifest.Version)
# SSIS Copilot Toolkit overlay version. Managed by install/Add-CopilotSsisToolkit.ps1.
# Source: $($source.Origin)
# Installed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ssK')
"@
    if (Test-ShouldProcess -Target $stamp -Action 'Write version stamp') {
        Write-TextFile -Path $stamp -Content $stampContent
        Write-Host ""
        Write-Host "Wrote version stamp: $stamp"
    }
}
finally {
    # Clean up the staged archive even if an entry failed midway.
    if ($source.Staged -and $source.StagingRoot) {
        Remove-Item -LiteralPath $source.StagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Done."
Write-Host "Next steps:"
Write-Host "  1. Review the appended block in AGENTS.md."
Write-Host "  2. Build the managed-OM host:  .\tools\lib\SsisOmHost\Build-SsisOmHost.ps1"
Write-Host "  3. Open the repo in Visual Studio 2026 (18.4+) or VS Code with GitHub Copilot Chat."
Write-Host "  4. From Copilot Chat, select 'ssis-author' from the agent picker to start authoring packages."
