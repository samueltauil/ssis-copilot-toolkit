#requires -Version 5.1
<#
.SYNOPSIS
    Validates - and optionally installs - every prerequisite the SSIS Copilot Toolkit needs.

.DESCRIPTION
    Run this BEFORE anything else. It is the single answer to "what do I have to
    install first?". Nothing else in the toolkit works until this reports PASS.

    Deliberately written for Windows PowerShell 5.1 so it runs on a bare Windows
    box that does not have PowerShell 7 yet, and it resolves every path from its
    own location, so it works no matter which directory you run it from.

    Checks, grouped:

      Core   - required for any scenario (authoring + validation):
               Windows x64, PowerShell 5.1+, execution policy, repository
               integrity, a parseable .ssis-toolkit.json, Git, .NET Framework
               4.6.2+ with csc.exe, SQL Server 2025 Integration Services shared
               components (GAC v17 assemblies + dtexec.exe), and a real compile
               of the managed-OM host.

      Demo   - required only to run the AdventureWorks walkthrough:
               SqlServer PowerShell module, connectivity to the SQL Server
               instance named in .ssis-toolkit.json, the source and target
               databases, and the SSISDB catalog (deployment only).

      IDE    - recommended, never fatal:
               PowerShell 7, an IDE with GitHub Copilot Chat, winget.

    Every failure prints the exact remediation command. With -Install the script
    installs what can be installed unattended (Git, PowerShell 7, and the
    SqlServer module), then re-runs all checks from scratch and reports the
    post-install state. It never installs SQL Server, never restores a database,
    and never creates SSISDB - those are deliberate, high-impact operations.

.PARAMETER Install
    Attempt to install missing installable prerequisites (Git and PowerShell 7
    via winget; the SqlServer module via PowerShellGet), then re-verify.

.PARAMETER Server
    SQL Server instance to test for the demo checks. Defaults to the target
    connection's server in .ssis-toolkit.json.

.PARAMETER SkipDemo
    Skip the SQL Server checks. Use when you only need to author and validate
    packages against your own metadata.

.PARAMETER SkipBuild
    Skip the managed-OM host compile. The compile is the only check that proves
    the SSIS assemblies are genuinely usable, so skip it only for a fast re-check.

.PARAMETER PassThru
    Emit the result objects to the pipeline in addition to the console report.

.OUTPUTS
    None by default. With -PassThru, one PSCustomObject per check with the
    fields Id, Category, Requirement, Required, Status, Detail, Fix, Fixable.

.NOTES
    Exit code 0 = every required check passed (warnings allowed).
    Exit code 1 = at least one required check failed.

.EXAMPLE
    .\install\Test-Prerequisites.ps1

.EXAMPLE
    .\install\Test-Prerequisites.ps1 -Install

.EXAMPLE
    .\install\Test-Prerequisites.ps1 -SkipDemo -SkipBuild
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$Server,
    [switch]$SkipDemo,
    [switch]$SkipBuild,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The managed-OM host binds to these exact assembly versions. Changing them means
# changing tools/lib/SsisOmHost/Build-SsisOmHost.ps1 in lockstep.
$script:RequiredGacVersion   = 'v4.0_17.0.0.0'
$script:RequiredSqlMajor     = '170'
$script:MinDotNetRelease     = 394802   # .NET Framework 4.6.2
$script:RepoRoot             = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:Results              = $null
$script:ToolkitConfig        = $null
$script:BuildOutput          = @()

# --- reporting helpers -------------------------------------------------------

function New-Result {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Core', 'Demo', 'IDE')][string]$Category,
        [Parameter(Mandatory)][string]$Requirement,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Fail', 'Warn', 'Skip')][string]$Status,
        [string]$Detail = '',
        [string]$Fix = '',
        [string]$Fixable = ''
    )
    $script:Results.Add([pscustomobject]@{
            Id          = $Id
            Category    = $Category
            Requirement = $Requirement
            Required    = ($Category -ne 'IDE')
            Status      = $Status
            Detail      = $Detail
            Fix         = $Fix
            Fixable     = $Fixable   # non-empty = -Install can remediate; value is the handler key
        })
}

function Write-Heading([string]$Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkGray
}

function Write-ResultLine($Result) {
    switch ($Result.Status) {
        'Pass' { $glyph = '[ OK ]'; $color = 'Green' }
        'Warn' { $glyph = '[WARN]'; $color = 'Yellow' }
        'Skip' { $glyph = '[SKIP]'; $color = 'DarkGray' }
        default { $glyph = '[FAIL]'; $color = 'Red' }
    }
    Write-Host ("{0} {1}" -f $glyph, $Result.Requirement) -ForegroundColor $color
    if ($Result.Detail) { Write-Host ("       {0}" -f $Result.Detail) -ForegroundColor DarkGray }
    if ($Result.Status -ne 'Pass' -and $Result.Fix) {
        Write-Host ("       Fix: {0}" -f $Result.Fix) -ForegroundColor DarkYellow
    }
}

# --- environment helpers -----------------------------------------------------

function Test-IsWindows {
    # $IsWindows does not exist in Windows PowerShell 5.1.
    if ($PSVersionTable.PSVersion.Major -lt 6) { return $true }
    return [bool]$IsWindows
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-SessionPath {
    # winget installs edit the registry, not this process. Merge in any new
    # entries so the post-install verification pass can find the executables,
    # without discarding process-only entries this session already had.
    $current = @($env:Path -split ';' | Where-Object { $_ })
    foreach ($scope in 'Machine', 'User') {
        $stored = [Environment]::GetEnvironmentVariable('Path', $scope)
        if (-not $stored) { continue }
        foreach ($entry in ($stored -split ';' | Where-Object { $_ })) {
            if ($current -notcontains $entry) { $current += $entry }
        }
    }
    $env:Path = $current -join ';'
}

function Get-CommandVersion {
    param([Parameter(Mandatory)][string]$Name, [string[]]$Arguments = @('--version'))
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $null }
    $raw = ''
    try { $raw = (& $cmd.Source @Arguments 2>&1 | Select-Object -First 1) } catch { $raw = '' }
    return [pscustomobject]@{ Path = $cmd.Source; Version = ("$raw").Trim() }
}

# --- individual checks -------------------------------------------------------

function Test-Platform {
    if (-not (Test-IsWindows)) {
        New-Result -Id 'os' -Category Core -Requirement 'Windows operating system' -Status Fail `
            -Detail "Detected $([System.Environment]::OSVersion.VersionString)." `
            -Fix 'SSIS authoring and execution are Windows-only. Use a Windows machine or VM.'
        return
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        New-Result -Id 'os' -Category Core -Requirement 'Windows operating system (64-bit)' -Status Fail `
            -Detail '32-bit Windows detected.' `
            -Fix 'The toolkit compiles and runs a 64-bit host. Use 64-bit Windows.'
        return
    }
    New-Result -Id 'os' -Category Core -Requirement 'Windows operating system (64-bit)' -Status Pass `
        -Detail ([System.Environment]::OSVersion.VersionString)
}

function Test-PowerShellHost {
    $v = $PSVersionTable.PSVersion
    if ($v.Major -lt 5 -or ($v.Major -eq 5 -and $v.Minor -lt 1)) {
        New-Result -Id 'pshost' -Category Core -Requirement 'PowerShell 5.1 or later (current host)' -Status Fail `
            -Detail "Running PowerShell $v." `
            -Fix 'Install Windows Management Framework 5.1 or PowerShell 7: winget install --id Microsoft.PowerShell --exact'
        return
    }
    New-Result -Id 'pshost' -Category Core -Requirement 'PowerShell 5.1 or later (current host)' -Status Pass `
        -Detail "PowerShell $v ($($PSVersionTable.PSEdition))"
}

function Test-ExecutionPolicy {
    $blocking = @('Restricted', 'AllSigned')
    $effective = Get-ExecutionPolicy
    if ($blocking -contains [string]$effective) {
        New-Result -Id 'execpolicy' -Category Core -Requirement 'Execution policy allows local scripts' -Status Fail `
            -Detail "Effective policy is '$effective'; toolkit .ps1 files will not run." `
            -Fix 'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   (or launch with: powershell -ExecutionPolicy Bypass -File ...)'
        return
    }
    New-Result -Id 'execpolicy' -Category Core -Requirement 'Execution policy allows local scripts' -Status Pass `
        -Detail "Effective policy: $effective"
}

function Test-Git {
    $git = Get-CommandVersion -Name 'git.exe'
    if (-not $git) {
        # Not fatal: authoring and the validation gate never shell out to git.
        # You need it to clone, and for the clean-clone round-trip gate.
        New-Result -Id 'git' -Category Core -Requirement 'Git for Windows' -Status Warn `
            -Detail "'git' is not on PATH. Authoring and validation still work (you can use a downloaded ZIP of the repo), but you cannot clone, pull, or run the clean-clone round-trip gate." `
            -Fix 'winget install --id Git.Git --exact --source winget    (then open a NEW terminal)' `
            -Fixable 'git'
        return
    }
    New-Result -Id 'git' -Category Core -Requirement 'Git for Windows' -Status Pass `
        -Detail "$($git.Version) - $($git.Path)"
}

function Test-DotNetFramework {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) {
        New-Result -Id 'csc' -Category Core -Requirement '.NET Framework 4.x C# compiler (csc.exe)' -Status Fail `
            -Detail "Not found at $csc." `
            -Fix 'Install .NET Framework 4.8: winget install --id Microsoft.DotNet.Framework.DeveloperPack_4 --exact'
        return
    }

    $release = $null
    $key = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    if (Test-Path -LiteralPath $key) {
        $release = (Get-ItemProperty -LiteralPath $key -Name Release -ErrorAction SilentlyContinue).Release
    }
    if ($release -and $release -lt $script:MinDotNetRelease) {
        New-Result -Id 'csc' -Category Core -Requirement '.NET Framework 4.6.2 or later' -Status Fail `
            -Detail "Release $release is below the required $($script:MinDotNetRelease)." `
            -Fix 'Install .NET Framework 4.8: winget install --id Microsoft.DotNet.Framework.DeveloperPack_4 --exact'
        return
    }

    $detail = "csc.exe present"
    if ($release) { $detail += " (NDP v4 Full release $release)" }
    New-Result -Id 'csc' -Category Core -Requirement '.NET Framework 4.6.2 or later with csc.exe' -Status Pass -Detail $detail
}

function Test-SsisSharedComponents {
    $gacRoot = Join-Path $env:WINDIR 'Microsoft.NET\assembly'
    $needed = @(
        @{ Gac = 'GAC_MSIL'; Name = 'Microsoft.SqlServer.ManagedDTS' }
        @{ Gac = 'GAC_MSIL'; Name = 'Microsoft.SqlServer.DTSPipelineWrap' }
        @{ Gac = 'GAC_64'; Name = 'Microsoft.SqlServer.DTSRuntimeWrap' }
    )

    $missing = @()
    $otherVersions = @()
    foreach ($asm in $needed) {
        $folder = Join-Path (Join-Path $gacRoot $asm.Gac) $asm.Name
        if (-not (Test-Path -LiteralPath $folder)) { $missing += $asm.Name; continue }
        $versions = @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Name)
        # GAC folder names are "<version>__<publicKeyToken>", e.g. v4.0_17.0.0.0__89845dcd8080cc91.
        $match = @($versions | Where-Object { $_ -like ($script:RequiredGacVersion + '__*') })
        if ($match.Count -eq 0) {
            $missing += $asm.Name
            $otherVersions += ("{0} -> {1}" -f $asm.Name, (($versions -join ', ')))
        }
    }

    if ($missing.Count -gt 0) {
        $detail = "Missing $($script:RequiredGacVersion) in the GAC for: $($missing -join ', ')."
        if ($otherVersions.Count -gt 0) {
            $detail += " Installed versions: $($otherVersions -join '; '). v4.0_16.0.0.0 is SQL Server 2022 and is NOT sufficient."
        }
        New-Result -Id 'ssisgac' -Category Core -Requirement 'SQL Server 2025 Integration Services shared components' -Status Fail `
            -Detail $detail `
            -Fix 'Run the SQL Server 2025 installer and select "Integration Services" under Shared Features. The database engine alone does not install these assemblies.'
        return
    }

    New-Result -Id 'ssisgac' -Category Core -Requirement 'SQL Server 2025 Integration Services shared components' -Status Pass `
        -Detail "All three GAC assemblies present at $($script:RequiredGacVersion)."
}

function Test-Dtexec {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    $found = @()
    foreach ($root in $roots) {
        $sqlRoot = Join-Path $root 'Microsoft SQL Server'
        if (-not (Test-Path -LiteralPath $sqlRoot)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $sqlRoot -Directory -ErrorAction SilentlyContinue)) {
            if ($dir.Name -notmatch '^\d+$') { continue }
            $exe = Join-Path $dir.FullName 'DTS\Binn\dtexec.exe'
            if (Test-Path -LiteralPath $exe) {
                $found += [pscustomobject]@{ Major = $dir.Name; Path = $exe }
            }
        }
    }

    $required = $found | Where-Object { $_.Major -eq $script:RequiredSqlMajor } | Select-Object -First 1
    if ($required) {
        New-Result -Id 'dtexec' -Category Core -Requirement "dtexec.exe (SQL Server $($script:RequiredSqlMajor))" -Status Pass `
            -Detail $required.Path
        return
    }

    $detail = if ($found.Count -gt 0) {
        "Found only: $(($found | ForEach-Object { "$($_.Major) -> $($_.Path)" }) -join '; ')."
    }
    else {
        'No dtexec.exe found under any "Microsoft SQL Server\<major>\DTS\Binn" folder.'
    }
    New-Result -Id 'dtexec' -Category Core -Requirement "dtexec.exe (SQL Server $($script:RequiredSqlMajor))" -Status Fail `
        -Detail $detail `
        -Fix 'Install SQL Server 2025 Integration Services shared components (same installer step as the GAC assemblies above).'
}

function Test-RepositoryIntegrity {
    # The most common reported failure is running the documented commands from the
    # wrong directory. Prove the toolkit files are where this script expects them.
    $required = @(
        'tools/lib/SsisOmHost/Build-SsisOmHost.ps1'
        'tools/lib/SsisOmHost/Program.cs'
        'tools/New-SsisPackage.ps1'
        'tools/Test-SsisPackage.ps1'
        'tools/Test-SsisDesignerLoad.ps1'
        'tools/lib/ToolkitConfig.psm1'
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RepoRoot $_)) })
    if ($missing.Count -gt 0) {
        New-Result -Id 'repo' -Category Core -Requirement 'Toolkit files present' -Status Fail `
            -Detail "Missing under $($script:RepoRoot): $($missing -join ', ')." `
            -Fix 'Re-clone the repository and run this script from inside the clone.'
        return
    }

    $cwdOk = (Get-Location).Path.TrimEnd('\') -ieq $script:RepoRoot.TrimEnd('\')
    $detail = "Repository root: $($script:RepoRoot)"
    if (-not $cwdOk) {
        $cwd = (Get-Location).Path
        $detail = "{0} (current directory is {1} - run: cd '{2}' before using the documented .\tools\... commands)" -f $detail, $cwd, $script:RepoRoot
        New-Result -Id 'repo' -Category Core -Requirement 'Toolkit files present' -Status Pass -Detail $detail
        return
    }
    New-Result -Id 'repo' -Category Core -Requirement 'Toolkit files present' -Status Pass -Detail $detail
}

function Test-ToolkitConfig {
    # Every primitive resolves its paths, connections, and schema names through
    # this file. Malformed JSON degrades silently everywhere else, so fail here.
    $configPath = Join-Path $script:RepoRoot '.ssis-toolkit.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        New-Result -Id 'config' -Category Core -Requirement '.ssis-toolkit.json at the repository root' -Status Warn `
            -Detail 'Not found. Paths and schema names fall back to defaults, and the SQL checks below have no server to test.' `
            -Fix 'Run /scaffold-new-ssis-project in Copilot Chat, or copy .ssis-toolkit.example.json and edit it.'
        return
    }

    try {
        $script:ToolkitConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    }
    catch {
        New-Result -Id 'config' -Category Core -Requirement '.ssis-toolkit.json is valid JSON' -Status Fail `
            -Detail "Could not parse $configPath : $($_.Exception.Message)" `
            -Fix 'Correct the JSON syntax, or regenerate the file with /scaffold-new-ssis-project.'
        return
    }

    $parts = @()
    foreach ($key in 'projectName', 'projectPath', 'metadataPath') {
        if ($script:ToolkitConfig.PSObject.Properties.Match($key).Count) {
            $parts += "$key=$($script:ToolkitConfig.$key)"
        }
    }
    $detail = if ($parts.Count -gt 0) { $parts -join '; ' } else { 'Parsed, but no project keys set.' }
    New-Result -Id 'config' -Category Core -Requirement '.ssis-toolkit.json at the repository root' -Status Pass -Detail $detail
}

function Test-OmHostBuild {
    if ($SkipBuild) {
        New-Result -Id 'omhost' -Category Core -Requirement 'Managed-OM host compiles (SsisOmHost.exe)' -Status Skip `
            -Detail '-SkipBuild specified.'
        return
    }

    $blockers = @($script:Results | Where-Object { $_.Id -in @('csc', 'ssisgac', 'repo') -and $_.Status -eq 'Fail' })
    if ($blockers.Count -gt 0) {
        New-Result -Id 'omhost' -Category Core -Requirement 'Managed-OM host compiles (SsisOmHost.exe)' -Status Skip `
            -Detail "Skipped because a dependency failed: $(($blockers.Requirement) -join ', ')."
        return
    }

    $builder = Join-Path $script:RepoRoot 'tools\lib\SsisOmHost\Build-SsisOmHost.ps1'
    $exe = Join-Path $script:RepoRoot 'tools\lib\SsisOmHost\SsisOmHost.exe'
    $script:BuildOutput = @()
    try {
        $script:BuildOutput = @(& $builder -Force 2>&1)
        if (-not (Test-Path -LiteralPath $exe)) { throw "Build reported success but $exe does not exist." }
        New-Result -Id 'omhost' -Category Core -Requirement 'Managed-OM host compiles (SsisOmHost.exe)' -Status Pass `
            -Detail $exe
    }
    catch {
        $tail = ($script:BuildOutput | Select-Object -Last 5 | ForEach-Object { "$_" }) -join ' | '
        $detail = $_.Exception.Message
        if ($tail) { $detail += "  [compiler output: $tail]" }
        New-Result -Id 'omhost' -Category Core -Requirement 'Managed-OM host compiles (SsisOmHost.exe)' -Status Fail `
            -Detail $detail `
            -Fix "Resolve the error above, then re-run: `"$builder`" -Force"
    }
}

function Test-SqlServerModule {
    if ($SkipDemo) {
        New-Result -Id 'sqlmodule' -Category Demo -Requirement 'SqlServer PowerShell module' -Status Skip `
            -Detail '-SkipDemo specified.'
        return
    }

    $module = Get-Module -ListAvailable -Name SqlServer |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) {
        New-Result -Id 'sqlmodule' -Category Demo -Requirement 'SqlServer PowerShell module' -Status Fail `
            -Detail "Not visible to this host (PowerShell $($PSVersionTable.PSVersion)). Windows PowerShell 5.1 and PowerShell 7 use separate module paths, so it must be installed in whichever host you run the toolkit scripts from." `
            -Fix 'Install-Module SqlServer -Scope CurrentUser -Force' `
            -Fixable 'sqlmodule'
        return
    }
    New-Result -Id 'sqlmodule' -Category Demo -Requirement 'SqlServer PowerShell module' -Status Pass `
        -Detail "Version $($module.Version) at $($module.ModuleBase)"
}

function Get-ToolkitConnectionInfo {
    if (-not $script:ToolkitConfig) { return $null }
    if (-not $script:ToolkitConfig.PSObject.Properties.Match('connections').Count) { return $null }
    return $script:ToolkitConfig.connections
}

function Get-SqlQueryRunner {
    # Two independent ways to reach SQL Server, in preference order:
    #   1. System.Data.SqlClient - present in Windows PowerShell 5.1, absent from
    #      the PowerShell 7 shared framework.
    #   2. Invoke-Sqlcmd from the SqlServer module - works in both hosts.
    # Returns $null when neither is available, so the caller can Skip cleanly.
    if ('System.Data.SqlClient.SqlConnection' -as [type]) { return 'SqlClient' }
    if (Get-Module -ListAvailable -Name SqlServer) { return 'InvokeSqlcmd' }
    return $null
}

function Invoke-SqlScalar {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][ValidateSet('SqlClient', 'InvokeSqlcmd')][string]$Runner,
        [int]$TimeoutSeconds = 10
    )

    if ($Runner -eq 'InvokeSqlcmd') {
        Import-Module SqlServer -ErrorAction Stop
        $row = Invoke-Sqlcmd -ServerInstance $Instance -Database master -Query $Query `
            -TrustServerCertificate -ConnectionTimeout $TimeoutSeconds -ErrorAction Stop
        if (-not $row) { return $null }
        return ($row | Select-Object -First 1 | ForEach-Object { $_[0] })
    }

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $Instance
    $builder['Initial Catalog'] = 'master'
    $builder['Integrated Security'] = $true
    $builder['Connect Timeout'] = $TimeoutSeconds
    $builder['TrustServerCertificate'] = $true
    $builder['Application Name'] = 'SsisToolkitPrereqCheck'

    $conn = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $TimeoutSeconds
        return $cmd.ExecuteScalar()
    }
    finally {
        $conn.Dispose()
    }
}

function Test-SqlEnvironment {
    if ($SkipDemo) {
        New-Result -Id 'sqlconn' -Category Demo -Requirement 'SQL Server instance reachable' -Status Skip `
            -Detail '-SkipDemo specified.'
        return
    }

    $connections = Get-ToolkitConnectionInfo
    $instance = $Server
    if (-not $instance -and $connections -and $connections.target) { $instance = $connections.target.server }
    if (-not $instance -and $connections -and $connections.source) { $instance = $connections.source.server }

    if (-not $instance) {
        New-Result -Id 'sqlconn' -Category Demo -Requirement 'SQL Server instance reachable' -Status Skip `
            -Detail 'No server configured in .ssis-toolkit.json and no -Server supplied.' `
            -Fix 'Pass -Server <instance>, or set connections.target.server in .ssis-toolkit.json.'
        return
    }

    $runner = Get-SqlQueryRunner
    if (-not $runner) {
        New-Result -Id 'sqlconn' -Category Demo -Requirement "SQL Server instance reachable ($instance)" -Status Fail `
            -Detail 'No SQL client available: this PowerShell host has no System.Data.SqlClient and the SqlServer module is not installed.' `
            -Fix 'Install-Module SqlServer -Scope CurrentUser -Force   (or re-run this script with -Install)'
        return
    }

    try {
        Invoke-SqlScalar -Instance $instance -Runner $runner -Query 'SELECT 1' | Out-Null
        $edition = Invoke-SqlScalar -Instance $instance -Runner $runner -Query "SELECT CONVERT(nvarchar(200), SERVERPROPERTY('ProductVersion')) + N' / ' + CONVERT(nvarchar(200), SERVERPROPERTY('Edition'))"
        New-Result -Id 'sqlconn' -Category Demo -Requirement "SQL Server instance reachable ($instance)" -Status Pass `
            -Detail $edition
    }
    catch {
        New-Result -Id 'sqlconn' -Category Demo -Requirement "SQL Server instance reachable ($instance)" -Status Fail `
            -Detail $_.Exception.Message `
            -Fix "Confirm the instance name and that the SQL Server service is running (Get-Service MSSQL*), then re-run. Different instance? Update connections.*.server in .ssis-toolkit.json or pass -Server."
        return
    }

    # Databases named by the repo config. No literal database names here - the
    # overlay must not assume any particular environment.
    $databases = @()
    foreach ($role in 'source', 'target') {
        if ($connections -and $connections.$role -and $connections.$role.database) {
            $databases += [pscustomobject]@{ Role = $role; Name = $connections.$role.database }
        }
    }

    foreach ($db in $databases) {
        try {
            $found = Invoke-SqlScalar -Instance $instance -Runner $runner -Query "SELECT name FROM sys.databases WHERE name = N'$($db.Name -replace "'", "''")'"
        }
        catch {
            $found = $null
        }
        if ($found) {
            New-Result -Id "db-$($db.Role)" -Category Demo -Requirement "$($db.Role) database '$($db.Name)'" -Status Pass `
                -Detail "Present on $instance."
        }
        elseif ($db.Role -eq 'target') {
            New-Result -Id "db-$($db.Role)" -Category Demo -Requirement "$($db.Role) database '$($db.Name)'" -Status Warn `
                -Detail "Not present on $instance." `
                -Fix 'Create it, or run this repo''s provisioning script under install\ if it ships one.'
        }
        else {
            New-Result -Id "db-$($db.Role)" -Category Demo -Requirement "$($db.Role) database '$($db.Name)'" -Status Fail `
                -Detail "Not present on $instance." `
                -Fix "Restore or create '$($db.Name)' on $instance. Sample databases: https://learn.microsoft.com/sql/samples/adventureworks-install-configure"
        }
    }

    try {
        $ssisdb = Invoke-SqlScalar -Instance $instance -Runner $runner -Query "SELECT name FROM sys.databases WHERE name = N'SSISDB'"
    }
    catch {
        $ssisdb = $null
    }
    if ($ssisdb) {
        New-Result -Id 'ssisdb' -Category Demo -Requirement 'SSISDB catalog (deployment only)' -Status Pass -Detail "Present on $instance."
    }
    else {
        New-Result -Id 'ssisdb' -Category Demo -Requirement 'SSISDB catalog (deployment only)' -Status Warn `
            -Detail "Not present on $instance. Authoring and the validation gate do not need it." `
            -Fix 'SSMS -> Integration Services Catalogs -> Create Catalog. Only needed if you deploy.'
    }
}

function Test-PowerShell7 {
    $pwsh = Get-CommandVersion -Name 'pwsh.exe' -Arguments @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()')
    if (-not $pwsh) {
        New-Result -Id 'pwsh' -Category IDE -Requirement 'PowerShell 7 (pwsh)' -Status Warn `
            -Detail "'pwsh' is not on PATH. The VS Code tasks in .vscode\tasks.json invoke 'pwsh'; without it, run the scripts with 'powershell' instead." `
            -Fix 'winget install --id Microsoft.PowerShell --exact --source winget    (then open a NEW terminal)' `
            -Fixable 'pwsh'
        return
    }
    New-Result -Id 'pwsh' -Category IDE -Requirement 'PowerShell 7 (pwsh)' -Status Pass `
        -Detail "$($pwsh.Version) - $($pwsh.Path)"
}

function Test-Ide {
    $found = @()
    $copilotSeen = $false

    foreach ($exe in 'code.cmd', 'code-insiders.cmd') {
        $cmd = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { continue }
        $extensions = @()
        try { $extensions = @(& $cmd.Source --list-extensions 2>$null) } catch { $extensions = @() }
        if (@($extensions | Where-Object { $_ -ieq 'github.copilot-chat' }).Count -gt 0) {
            $copilotSeen = $true
            $found += "$($cmd.Name) (Copilot Chat installed)"
        }
        else {
            $found += "$($cmd.Name) (no Copilot Chat)"
        }
    }

    $vsRoot = ${env:ProgramFiles(x86)}
    $vsFound = $false
    if ($vsRoot) {
        $vswhere = Join-Path $vsRoot 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $vs = @(& $vswhere -latest -products * -property catalog_productDisplayVersion 2>$null)
            if ($vs.Count -gt 0) {
                $vsFound = $true
                $found += "Visual Studio $($vs[0])"
            }
        }
    }

    if ($found.Count -eq 0) {
        New-Result -Id 'ide' -Category IDE -Requirement 'IDE with GitHub Copilot Chat' -Status Warn `
            -Detail 'Neither VS Code nor Visual Studio was detected on PATH.' `
            -Fix 'Install VS Code (winget install --id Microsoft.VisualStudioCode --exact) and the GitHub Copilot Chat extension, or use Visual Studio 2026 18.4+.'
        return
    }
    if (-not $copilotSeen -and -not $vsFound) {
        New-Result -Id 'ide' -Category IDE -Requirement 'IDE with GitHub Copilot Chat' -Status Warn `
            -Detail "IDE found but no GitHub Copilot Chat extension: $($found -join '; ')" `
            -Fix 'In VS Code: Extensions -> install "GitHub Copilot Chat", then sign in to GitHub.'
        return
    }
    New-Result -Id 'ide' -Category IDE -Requirement 'IDE with GitHub Copilot Chat' -Status Pass -Detail ($found -join '; ')
}

function Test-Winget {
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $winget) {
        New-Result -Id 'winget' -Category IDE -Requirement 'winget (used by -Install)' -Status Warn `
            -Detail 'winget not found; -Install cannot install Git or PowerShell 7 automatically.' `
            -Fix 'Install "App Installer" from the Microsoft Store, or install the missing tools manually.'
        return
    }
    New-Result -Id 'winget' -Category IDE -Requirement 'winget (used by -Install)' -Status Pass -Detail $winget.Source
}

# --- installers --------------------------------------------------------------

function Install-ViaWinget {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$VerifyCommand
    )

    if (-not (Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host "  Cannot install ${DisplayName}: winget is not available." -ForegroundColor Red
        return $false
    }
    Write-Host "  Installing $DisplayName ($PackageId) via winget..." -ForegroundColor Cyan
    & winget.exe install --id $PackageId --exact --source winget --silent `
        --accept-package-agreements --accept-source-agreements 2>&1 | Out-Host
    $code = $LASTEXITCODE
    Update-SessionPath

    # winget returns a wide range of non-zero codes that still leave a usable
    # install (already-installed, no-applicable-upgrade, reboot-pending). Trust
    # the command resolving on PATH over the exit code.
    if (Get-Command $VerifyCommand -CommandType Application -ErrorAction SilentlyContinue) {
        if ($code -ne 0) {
            Write-Host "  winget exited with $code but $VerifyCommand is now available." -ForegroundColor DarkGray
        }
        return $true
    }

    Write-Host "  winget exited with $code and $VerifyCommand is still not on PATH." -ForegroundColor Red
    Write-Host "  Install $DisplayName manually, then open a NEW terminal and re-run this script." -ForegroundColor DarkYellow
    return $false
}

function Install-SqlServerModule {
    Write-Host '  Installing the SqlServer PowerShell module (CurrentUser scope)...' -ForegroundColor Cyan
    try {
        # PSGallery over TLS 1.2 - Windows PowerShell 5.1 still defaults to TLS 1.0.
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Scope CurrentUser -Force | Out-Null
        }
        Install-Module -Name SqlServer -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "  Install-Module SqlServer failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Retry manually: Install-Module SqlServer -Scope CurrentUser -Force' -ForegroundColor DarkYellow
        return $false
    }
}

function Invoke-Remediation {
    param([Parameter(Mandatory)][object[]]$Failures)

    Write-Heading 'Installing missing prerequisites'

    if (-not (Test-IsElevated)) {
        Write-Host 'Not running elevated. winget may prompt for elevation, or fail for machine-scope installs.' -ForegroundColor Yellow
        Write-Host 'If an install fails, re-run this script from an elevated terminal.' -ForegroundColor Yellow
    }

    $anyAttempted = $false
    foreach ($failure in $Failures) {
        $anyAttempted = $true
        switch ($failure.Fixable) {
            'git' { Install-ViaWinget -PackageId 'Git.Git' -DisplayName 'Git for Windows' -VerifyCommand 'git.exe' | Out-Null }
            'pwsh' { Install-ViaWinget -PackageId 'Microsoft.PowerShell' -DisplayName 'PowerShell 7' -VerifyCommand 'pwsh.exe' | Out-Null }
            'sqlmodule' { Install-SqlServerModule | Out-Null }
            default { }
        }
    }
    return $anyAttempted
}

# --- orchestration -----------------------------------------------------------

function Invoke-AllChecks {
    $script:Results = New-Object System.Collections.Generic.List[object]
    $script:ToolkitConfig = $null

    Test-Platform
    Test-PowerShellHost
    Test-ExecutionPolicy
    Test-RepositoryIntegrity
    Test-ToolkitConfig
    Test-Git
    Test-DotNetFramework
    Test-SsisSharedComponents
    Test-Dtexec
    Test-OmHostBuild

    Test-SqlServerModule
    Test-SqlEnvironment

    Test-PowerShell7
    Test-Ide
    Test-Winget

    return $script:Results
}

function Write-Report {
    param([Parameter(Mandatory)][object[]]$Results)

    foreach ($category in 'Core', 'Demo', 'IDE') {
        $rows = @($Results | Where-Object { $_.Category -eq $category })
        if ($rows.Count -eq 0) { continue }
        $title = switch ($category) {
            'Core' { 'Core - required to author and validate packages' }
            'Demo' { 'Data environment - required to run packages against SQL Server' }
            default { 'Recommended - not fatal' }
        }
        Write-Heading $title
        foreach ($row in $rows) { Write-ResultLine $row }
    }
}

Write-Host ''
Write-Host 'SSIS Copilot Toolkit - prerequisite check' -ForegroundColor White
Write-Host "Repository: $script:RepoRoot" -ForegroundColor DarkGray

if ($Server -and $SkipDemo) {
    Write-Host '-Server is ignored because -SkipDemo was specified.' -ForegroundColor Yellow
}

$results = Invoke-AllChecks

if ($Install) {
    $fixable = @($results | Where-Object { $_.Status -in @('Fail', 'Warn') -and $_.Fixable })
    if ($fixable.Count -eq 0) {
        Write-Heading 'Installing missing prerequisites'
        Write-Host 'Nothing to install automatically.' -ForegroundColor DarkGray
    }
    else {
        Invoke-Remediation -Failures $fixable | Out-Null
        Write-Host ''
        Write-Host 'Re-running all checks after install...' -ForegroundColor Cyan
        $results = Invoke-AllChecks
    }
}

Write-Report -Results $results

$failed = @($results | Where-Object { $_.Required -and $_.Status -eq 'Fail' })
$warned = @($results | Where-Object { $_.Status -eq 'Warn' })

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "RESULT: FAIL - $($failed.Count) required prerequisite(s) missing." -ForegroundColor Red
    foreach ($f in $failed) { Write-Host "  - $($f.Requirement)" -ForegroundColor Red }
    if (-not $Install -and @($failed | Where-Object { $_.Fixable }).Count -gt 0) {
        Write-Host ''
        Write-Host 'Some of these can be installed for you: re-run with -Install.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Fix the items above and re-run this script. Do not continue until it reports PASS.' -ForegroundColor Yellow
}
else {
    Write-Host "RESULT: PASS - every required prerequisite is present." -ForegroundColor Green
    if ($warned.Count -gt 0) {
        Write-Host "$($warned.Count) recommendation(s) noted above; none block the toolkit." -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Next: cd into the repository root, then follow the getting-started steps in the README.' -ForegroundColor DarkGray
}

if ($PassThru) { $results }

if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
