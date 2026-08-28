<#
.SYNOPSIS
    Fails if the brownfield installer cannot bootstrap in every supported host.

.DESCRIPTION
    install/Add-CopilotSsisToolkit.ps1 is the one file in this repo that has to
    run before anything else exists on the target machine. It must work when
    invoked as a .ps1 and when piped through `iex (irm ...)`, under both
    Windows PowerShell 5.1 and pwsh 7. Those hosts differ in ways that are easy
    to regress:

      - 5.1 defines neither $IsWindows nor $PSVersionTable.Platform, so under
        Set-StrictMode a bare $IsWindows reference is a hard failure. That is
        the exact error this test exists to prevent.
      - Under iex there is no $PSCmdlet, so $PSCmdlet.ShouldProcess() throws.
      - Under iex there is no $PSCommandPath, so param defaults derived from it
        fail parameter binding.
      - Under iex a [Validate*] attribute in the top-level param block is
        applied to a pre-existing empty variable and throws.
      - 5.1 decodes a BOM-less .ps1 as ANSI, so a UTF-8 em dash arrives as a
        cp1252 smart quote that PowerShell honours as a string delimiter.

    Static assertions cover all five. The live install then proves the whole
    thing end to end, using SSIS_TOOLKIT_SOURCE_PATH so no network is needed.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's folder.

.EXAMPLE
    .\install\Test-InstallerBootstrap.ps1
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$installer = Join-Path $RepoRoot 'install/Add-CopilotSsisToolkit.ps1'
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message)
    if ($env:GITHUB_ACTIONS) { Write-Host "::error file=install/Add-CopilotSsisToolkit.ps1::$Message" }
    else { Write-Host "  FAIL  $Message" -ForegroundColor Red }
}

function Add-Pass {
    param([string]$Message)
    Write-Host "  ok    $Message" -ForegroundColor Green
}

if (-not (Test-Path -LiteralPath $installer)) {
    throw "Installer not found: $installer"
}

$text = [System.IO.File]::ReadAllText($installer)
$lines = $text -split "`r?`n"

Write-Host "Static bootstrap assertions"

# 1. Pure ASCII. The file ships without a BOM so `irm` sees clean text, which
#    means Windows PowerShell decodes it as ANSI when run as a .ps1.
$nonAscii = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    foreach ($ch in $lines[$i].ToCharArray()) {
        if ([int]$ch -gt 127) {
            $nonAscii += "line $($i + 1): U+{0:X4} '{1}'" -f [int]$ch, $ch
            break
        }
    }
}
if ($nonAscii.Count -gt 0) {
    Add-Failure "Installer must be pure ASCII (found $($nonAscii.Count) line(s), e.g. $($nonAscii[0]))."
}
else {
    Add-Pass 'Installer is pure ASCII.'
}

# 2. No BOM - a leading U+FEFF would be handed to iex as script text.
$bytes = [System.IO.File]::ReadAllBytes($installer)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Add-Failure 'Installer must not carry a UTF-8 BOM.'
}
else {
    Add-Pass 'Installer has no BOM.'
}

# The AST is the only reliable way to tell a real variable reference from the
# same word appearing in comment-based help.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    Add-Failure "Installer does not parse: $($parseErrors[0].Message)"
    Write-Host ""
    Write-Host "$($failures.Count) installer bootstrap failure(s)." -ForegroundColor Red
    exit 1
}
Add-Pass 'Installer parses cleanly.'

# The prerequisite checker has the same constraint for a different reason: it is
# the first thing a user runs, usually under Windows PowerShell 5.1, which
# decodes a BOM-less file as ANSI. A UTF-8 em dash then becomes a cp1252 smart
# quote, which PowerShell treats as a string delimiter, and the file stops
# parsing. Guard it here so the failure cannot come back.
$prereq = Join-Path $RepoRoot 'install/Test-Prerequisites.ps1'
if (-not (Test-Path -LiteralPath $prereq)) {
    Add-Failure "Prerequisite checker not found: $prereq"
}
else {
    $prereqNonAscii = @()
    $prereqLines = [System.IO.File]::ReadAllText($prereq) -split "`r?`n"
    for ($i = 0; $i -lt $prereqLines.Count; $i++) {
        foreach ($ch in $prereqLines[$i].ToCharArray()) {
            if ([int]$ch -gt 127) {
                $prereqNonAscii += "line $($i + 1): U+{0:X4} '{1}'" -f [int]$ch, $ch
                break
            }
        }
    }
    if ($prereqNonAscii.Count -gt 0) {
        Add-Failure "Test-Prerequisites.ps1 must be pure ASCII (found $($prereqNonAscii.Count) line(s), e.g. $($prereqNonAscii[0]))."
    }
    else {
        Add-Pass 'Test-Prerequisites.ps1 is pure ASCII.'
    }

    $prereqErrors = $null
    $prereqTokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($prereq, [ref]$prereqTokens, [ref]$prereqErrors) | Out-Null
    if ($prereqErrors -and $prereqErrors.Count -gt 0) {
        Add-Failure "Test-Prerequisites.ps1 does not parse: $($prereqErrors[0].Message)"
    }
    else {
        Add-Pass 'Test-Prerequisites.ps1 parses cleanly.'
    }
}

# 3. No bare platform automatic variables.
$platformNames = @('IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR')
$platformHits = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $platformNames -contains $node.VariablePath.UserPath
    }, $true) | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text)" })
if ($platformHits.Count -gt 0) {
    Add-Failure "Installer references a platform automatic variable directly (Windows PowerShell 5.1 does not define it): $($platformHits -join '; ')"
}
else {
    Add-Pass 'No direct $IsWindows/$IsLinux/$IsMacOS references.'
}

# 4. No direct $PSCmdlet member access - absent under iex.
$cmdletHits = @($ast.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.MemberExpressionAst]) -and
        ($node.Expression -is [System.Management.Automation.Language.VariableExpressionAst]) -and
        ($node.Expression.VariablePath.UserPath -eq 'PSCmdlet')
    }, $true) | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text)" })
if ($cmdletHits.Count -gt 0) {
    Add-Failure "Installer calls `$PSCmdlet directly (absent under iex); route through Test-ShouldProcess: $($cmdletHits -join '; ')"
}
else {
    Add-Pass 'No direct $PSCmdlet calls.'
}

# 5. Top-level param block free of validation attributes and host-derived defaults.
$paramBlock = $ast.ParamBlock
if ($paramBlock) {
    $paramClean = $true
    foreach ($p in $paramBlock.Parameters) {
        $name = $p.Name.VariablePath.UserPath
        foreach ($attr in $p.Attributes) {
            if ($attr.TypeName.Name -like 'Validate*') {
                Add-Failure "Parameter -$name carries [$($attr.TypeName.Name)]; validation attributes on the top-level param block throw under iex."
                $paramClean = $false
            }
        }
        if ($p.DefaultValue -and $p.DefaultValue.Extent.Text -match 'PSCommandPath|PSScriptRoot|Get-Location') {
            Add-Failure "Parameter -$name has a host-derived default ($($p.DefaultValue.Extent.Text)); resolve it in the bootstrap instead."
            $paramClean = $false
        }
    }
    if ($paramClean) {
        Add-Pass 'Param block has no validation attributes or host-derived defaults.'
    }
}

# 6. Live install through the iex code path, once per available host.
Write-Host ""
Write-Host "Live install (iex code path, local source via SSIS_TOOLKIT_SOURCE_PATH)"

$hosts = [ordered]@{}
$winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath $winPs) { $hosts['Windows PowerShell 5.1'] = $winPs }
$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwsh) { $hosts['pwsh 7'] = $pwsh.Source }

if ($hosts.Count -eq 0) {
    Write-Host "  skip  No PowerShell host available to run the live install." -ForegroundColor Yellow
}

foreach ($hostName in $hosts.Keys) {
    $exe = $hosts[$hostName]
    $failuresBefore = $failures.Count
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) "ssis-bootstrap-test-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null

    # Pre-existing content the installer must preserve rather than clobber.
    [System.IO.File]::WriteAllText((Join-Path $scratch '.gitignore'), "bin/`r`nobj/`r`n")
    [System.IO.File]::WriteAllText((Join-Path $scratch 'AGENTS.md'), "# Existing repo`r`n`r`nHouse rules.`r`n")

    # Invoke-Expression on the file's text is exactly what `iex (irm ...)` does:
    # no $PSCommandPath, no $PSCmdlet, param block evaluated in the caller scope.
    $driver = @"
`$env:SSIS_TOOLKIT_SOURCE_PATH = '$RepoRoot'
`$env:SSIS_TOOLKIT_REPO_PATH   = '$scratch'
Invoke-Expression ([System.IO.File]::ReadAllText('$installer'))
"@
    $driverPath = Join-Path $scratch '_driver.ps1'
    [System.IO.File]::WriteAllText($driverPath, $driver)

    $output = & $exe -NoProfile -ExecutionPolicy Bypass -File $driverPath 2>&1
    $exit = $LASTEXITCODE
    Remove-Item -LiteralPath $driverPath -Force -ErrorAction SilentlyContinue

    if ($exit -ne 0) {
        Add-Failure "$hostName - installer exited $exit via iex: $(($output | Select-Object -Last 5) -join ' | ')"
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        continue
    }

    $expected = @(
        '.github/copilot-instructions.md'
        '.github/agents'
        '.github/skills'
        'tools/New-SsisPackage.ps1'
        'tools/lib/patterns'
        '.copilot-ssis-toolkit-version'
    )
    $missing = @($expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $scratch $_)) })
    if ($missing.Count -gt 0) {
        Add-Failure "$hostName - overlay incomplete, missing: $($missing -join ', ')"
    }

    $agents = [System.IO.File]::ReadAllText((Join-Path $scratch 'AGENTS.md'))
    if ($agents -notmatch 'House rules\.') {
        Add-Failure "$hostName - installer discarded existing AGENTS.md content."
    }
    if (([regex]::Matches($agents, 'BEGIN: ssis-copilot-toolkit')).Count -ne 1) {
        Add-Failure "$hostName - AGENTS.md managed block was not written exactly once."
    }

    foreach ($managed in '.gitignore', 'AGENTS.md') {
        $b = [System.IO.File]::ReadAllBytes((Join-Path $scratch $managed))
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
            Add-Failure "$hostName - wrote $managed with a UTF-8 BOM."
        }
    }

    if ($failures.Count -eq $failuresBefore) { Add-Pass "$hostName - installed and merged cleanly via iex." }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) installer bootstrap failure(s)." -ForegroundColor Red
    Write-Host "install/Add-CopilotSsisToolkit.ps1 must run under Windows PowerShell 5.1 and pwsh 7, as a .ps1 and via iex."
    exit 1
}

Write-Host "Installer bootstraps correctly in every checked host." -ForegroundColor Green
exit 0
