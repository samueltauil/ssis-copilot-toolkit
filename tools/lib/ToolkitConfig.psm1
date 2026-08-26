# ToolkitConfig.psm1 — reads .ssis-toolkit.json, the repo-scoped configuration
# that tells the toolkit where THIS repository keeps its SSIS project, metadata
# JSON, validation SQL, and docs, plus the connections and warehouse schema
# names it uses.
#
# Every path in the toolkit flows through here so nothing hard-codes a demo
# folder layout or a demo database name.

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:ConfigFileName = '.ssis-toolkit.json'

# Neutral defaults for a repo that has no .ssis-toolkit.json yet. Deliberately
# generic — the demo repo pins its own values in .ssis-toolkit.json.
$script:DefaultConfig = @{
    projectPath       = 'ssis-project'
    projectName       = 'SsisProject'
    metadataPath      = 'metadata'
    validationSqlPath = 'sql/validation'
    docsPath          = 'docs'
    connections       = @{
        source = @{ name = 'Source';    server = ''; database = '' }
        target = @{ name = 'Warehouse'; server = ''; database = '' }
    }
    schemas           = @{
        staging   = 'stg'
        dimension = 'dim'
        fact      = 'fact'
    }
}

function ConvertTo-ToolkitHashtable {
    param([Parameter(Mandatory)][AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($key in $InputObject.Keys) {
            $out[[string]$key] = ConvertTo-ToolkitHashtable $InputObject[$key]
        }
        return $out
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $out = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $out[$prop.Name] = ConvertTo-ToolkitHashtable $prop.Value
        }
        return $out
    }

    return $InputObject
}

function Merge-ToolkitDefaults {
    param(
        [Parameter(Mandatory)][hashtable]$Defaults,
        [Parameter(Mandatory)][AllowNull()][hashtable]$Override
    )

    $merged = @{}
    foreach ($key in $Defaults.Keys) { $merged[$key] = $Defaults[$key] }
    if ($null -eq $Override) { return $merged }

    foreach ($key in $Override.Keys) {
        if ($merged.ContainsKey($key) -and
            $merged[$key] -is [hashtable] -and
            $Override[$key] -is [hashtable]) {
            $merged[$key] = Merge-ToolkitDefaults -Defaults $merged[$key] -Override $Override[$key]
        }
        else {
            $merged[$key] = $Override[$key]
        }
    }
    return $merged
}

<#
.SYNOPSIS
    Find the nearest .ssis-toolkit.json by walking up from a starting directory.

.OUTPUTS
    The full path to the config file, or $null when no config exists.
#>
function Find-SsisToolkitConfigPath {
    [CmdletBinding()]
    param([string]$StartPath = $PWD.Path)

    $dir = if (Test-Path -LiteralPath $StartPath -PathType Container) {
        (Resolve-Path -LiteralPath $StartPath).Path
    }
    else {
        [System.IO.Path]::GetDirectoryName((Resolve-Path -LiteralPath $StartPath).Path)
    }

    while ($dir) {
        $candidate = Join-Path $dir $script:ConfigFileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        $parent = [System.IO.Path]::GetDirectoryName($dir)
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

<#
.SYNOPSIS
    Load the toolkit configuration, applying defaults for anything unset.

.DESCRIPTION
    Returns a hashtable with the config values plus two computed keys:
      RepoRoot   — directory containing .ssis-toolkit.json (or $StartPath when absent)
      ConfigPath — full path to the config file, or $null when using defaults

    Never throws when the file is missing; callers that require explicit
    connection details should validate the returned values themselves.
#>
function Get-SsisToolkitConfig {
    [CmdletBinding()]
    param([string]$StartPath = $PWD.Path)

    $configPath = Find-SsisToolkitConfigPath -StartPath $StartPath

    $override = $null
    $repoRoot = (Resolve-Path -LiteralPath $StartPath).Path

    if ($configPath) {
        $repoRoot = [System.IO.Path]::GetDirectoryName($configPath)
        $raw = Get-Content -LiteralPath $configPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $override = ConvertTo-ToolkitHashtable (ConvertFrom-Json $raw)
            }
            catch {
                throw "Invalid JSON in $configPath : $($_.Exception.Message)"
            }
        }
    }

    if ($null -ne $override) { $override.Remove('$schema') }

    $config = Merge-ToolkitDefaults -Defaults $script:DefaultConfig -Override $override
    $config['RepoRoot']   = $repoRoot
    $config['ConfigPath'] = $configPath
    return $config
}

<#
.SYNOPSIS
    Resolve a repo-relative path from the config against the repo root.
#>
function Resolve-SsisToolkitPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not $Config.ContainsKey($Key)) {
        throw "Toolkit config has no '$Key' entry."
    }
    $value = [string]$Config[$Key]
    if ([System.IO.Path]::IsPathRooted($value)) { return $value }
    return Join-Path $Config['RepoRoot'] ($value -replace '/', [System.IO.Path]::DirectorySeparatorChar)
}

<#
.SYNOPSIS
    Write .ssis-toolkit.json to the given repo root.
#>
function Save-SsisToolkitConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $emit = @{}
    foreach ($key in $Config.Keys) {
        if ($key -in @('RepoRoot', 'ConfigPath')) { continue }
        $emit[$key] = $Config[$key]
    }

    $path = Join-Path $RepoRoot $script:ConfigFileName
    if ($PSCmdlet.ShouldProcess($path, 'Write toolkit configuration')) {
        $json = $emit | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
    }
    return $path
}

Export-ModuleMember -Function Find-SsisToolkitConfigPath, Get-SsisToolkitConfig,
                              Resolve-SsisToolkitPath, Save-SsisToolkitConfig
