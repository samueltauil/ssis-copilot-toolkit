<#
.SYNOPSIS
    Fails if any file shipped in the overlay assumes the demo environment.

.DESCRIPTION
    The overlay is what a customer's existing SSIS repo receives. It must contain
    nothing that assumes the AdventureWorks2025 demo databases, the demo SQL Server
    instance, or this repo's templates/ folder layout — otherwise the "drop it into
    your own repo" story breaks.

    Reads install/overlay.manifest.psd1 so it can never drift from the actual
    shipping list. Run it locally before opening a PR; CI runs it too.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's folder.

.EXAMPLE
    .\install\Test-OverlayPortability.ps1
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Push-Location (Resolve-Path -LiteralPath $RepoRoot)
try {
    $manifest = Import-PowerShellDataFile -LiteralPath 'install/overlay.manifest.psd1'

    # Tokens that tie a file to the demo environment or the demo folder layout.
    #
    # "AdventureWorks" on its own is deliberately NOT banned: it is a public Microsoft
    # sample that customers legitimately use, and overlay files may reference it
    # conditionally ("when the source is AdventureWorks2025, load the mapping skill").
    # What must never ship is a demo default — hence the .conmgr rule below.
    $banned = @(
        @{ Pattern = 'AdventureWorks\w*\.conmgr'; Why = 'demo connection manager' }
        @{ Pattern = 'CopilotSSIS';               Why = 'demo warehouse database' }
        @{ Pattern = 'CopilotSsis';               Why = 'demo project name' }
        @{ Pattern = 'SQL2025';                   Why = 'demo SQL Server instance' }
        @{ Pattern = 'templates[\\/]';            Why = 'demo folder layout' }
    )

    # The AdventureWorks mapping skill is demo-specific by design and ships so that
    # customers who genuinely use AdventureWorks get pinned column names.
    $allowed = @('.github/skills/adventureworks-mapping/')

    # AppendBlock targets (.gitignore, AGENTS.md) contribute manifest-defined blocks,
    # not their own file contents, so they are not scanned here.
    $scanActions = @('Copy', 'CopyDir', 'CopyIfMissing')

    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $manifest.Overlay) {
        if ($scanActions -notcontains $entry.Action) { continue }
        $path = $entry.Path
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Warning "Manifest lists '$path' but it does not exist."
            continue
        }
        if (Test-Path -LiteralPath $path -PathType Container) {
            Get-ChildItem -LiteralPath $path -Recurse -File | ForEach-Object {
                $files.Add(($_.FullName.Substring((Get-Location).Path.Length + 1)))
            }
        }
        else {
            $files.Add($path)
        }
    }

    $violations = @()
    foreach ($file in ($files | Sort-Object -Unique)) {
        $normalized = $file -replace '\\', '/'
        if (@($allowed | Where-Object { $normalized.StartsWith($_) }).Count -gt 0) { continue }

        $lines = @(Get-Content -LiteralPath $file)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            foreach ($rule in $banned) {
                if ($lines[$i] -match $rule.Pattern) {
                    $violations += [pscustomobject]@{
                        File   = $normalized
                        Line   = $i + 1
                        Reason = $rule.Why
                        Text   = $lines[$i].Trim()
                    }
                }
            }
        }
    }

    Write-Host "Scanned $($files.Count) overlay file(s)."

    if ($violations.Count -gt 0) {
        foreach ($v in $violations) {
            if ($env:GITHUB_ACTIONS) {
                Write-Host "::error file=$($v.File),line=$($v.Line)::Overlay file references $($v.Reason): $($v.Text)"
            }
            else {
                Write-Host "$($v.File):$($v.Line) [$($v.Reason)] $($v.Text)" -ForegroundColor Red
            }
        }
        Write-Host ""
        Write-Host "$($violations.Count) portability violation(s). Overlay files must not assume the demo environment." -ForegroundColor Red
        Write-Host "Move demo-only content to the manifest's Demo list, or make the value configurable via .ssis-toolkit.json."
        exit 1
    }

    Write-Host "No portability violations found." -ForegroundColor Green
    exit 0
}
finally {
    Pop-Location
}
