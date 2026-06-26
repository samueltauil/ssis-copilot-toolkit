# StagingLoad.psm1 — implements the documented "staging" pattern.
#
# Control flow (from .github/skills/ssis-package-patterns/SKILL.md):
#   Execute SQL (TRUNCATE if truncateBeforeLoad)
#   → Data Flow Task
#       OLE_SRC (sourceQuery)
#       → Derived Column adding LoadedAt + LoadedByPackageRunId audit cols
#       → OLE_DST (targetTable, FastLoad TABLOCK 10000 rows/batch)
#   → Execute SQL INSERT into etl.PackageRun
#
# This module ONLY orchestrates SsisOm helpers. No raw OM calls.

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\SsisOm.psm1') -Force

function New-StagingPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Metadata,
        [Parameter(Mandatory)][string]$OutputPath
    )

    foreach ($req in 'packageName','sourceConnection','targetConnection','targetTable') {
        if (-not $Metadata.ContainsKey($req)) { throw "staging metadata: missing required field '$req'." }
    }
    $sourceQuery = Resolve-SourceQuery -Metadata $Metadata
    $targetTable = $Metadata['targetTable']
    if (-not ($targetTable -match '^\[?stg\]?\.')) {
        throw "staging metadata: targetTable '$targetTable' must be in the 'stg' schema."
    }
    $truncate = if ($Metadata.ContainsKey('truncateBeforeLoad')) { [bool]$Metadata['truncateBeforeLoad'] } else { $true }

    # The connections referenced by Metadata.sourceConnection / .targetConnection are PROJECT-LEVEL
    # connection managers (Source.conmgr / Warehouse.conmgr). At package-author time we materialize
    # equivalent package-level OLE DB connections with the same names so the package validates
    # standalone. When the package is added to the project, the project-level managers win.
    $cnSource = Resolve-PackageConnection -Metadata $Metadata -Role 'source'
    $cnTarget = Resolve-PackageConnection -Metadata $Metadata -Role 'target'

    $pkg = New-SsisPackage -Name $Metadata['packageName']
    $src = Add-OleDbConnection -Package $pkg -Name $Metadata['sourceConnection'] `
        -ServerName $cnSource.Server -InitialCatalog $cnSource.Database
    $tgt = Add-OleDbConnection -Package $pkg -Name $Metadata['targetConnection'] `
        -ServerName $cnTarget.Server -InitialCatalog $cnTarget.Database

    if ($truncate) {
        Add-ExecuteSqlTask -Package $pkg -Name 'SQL Truncate Target' `
            -Connection $tgt -SqlStatement "TRUNCATE TABLE $targetTable;" | Out-Null
    }

    $dft = Add-DataFlowTask -Package $pkg -Name 'DFT Load Stg'

    $oleSrc = Add-OleDbSource -DataFlow $dft -Name 'OLE_SRC Source' `
        -Connection $src -SqlCommand $sourceQuery

    $auditExpressions = [ordered]@{
        'LoadedAt'              = '@[$Project::RunDate]'
        'LoadedByPackageRunId'  = '@[$Project::LoadedByPackageRunId]'
    }
    $derived = Add-DerivedColumn -DataFlow $dft -Name 'DC Audit' -Expressions $auditExpressions

    $oleDst = Add-OleDbDestination -DataFlow $dft -Name 'OLE_DST Stg' `
        -Connection $tgt -Table $targetTable

    Connect-DataFlowComponents -DataFlow $dft -From $oleSrc -To $derived
    Connect-DataFlowComponents -DataFlow $dft -From $derived -To $oleDst
    Initialize-OleDbDestinationMapping -Destination $oleDst

    Add-ExecuteSqlTask -Package $pkg -Name 'SQL Insert PackageRun' `
        -Connection $tgt -SqlStatement @"
INSERT INTO etl.PackageRun (PackageName, StartedAt, FinishedAt, Status, RowsLoaded)
VALUES (N'$($Metadata['packageName'])', @[`$Project::RunDate], SYSUTCDATETIME(), N'Succeeded', NULL);
"@ | Out-Null

    Save-SsisPackage -Package $pkg -Path $OutputPath
}

function Resolve-SourceQuery {
    param([hashtable]$Metadata)
    if ($Metadata.ContainsKey('sourceQuery') -and $Metadata['sourceQuery']) {
        return [string]$Metadata['sourceQuery']
    }
    # Derive from explicit user inputs: source.schema, source.table, columns[].source
    if (-not $Metadata.ContainsKey('source')) {
        throw "staging metadata: either 'sourceQuery' or 'source' (with schema/table) is required."
    }
    $src = [hashtable]$Metadata['source']
    foreach ($k in 'schema','table') {
        if (-not $src.ContainsKey($k)) { throw "staging metadata: source.$k is required." }
    }
    if (-not $Metadata.ContainsKey('columns') -or $Metadata['columns'].Count -eq 0) {
        throw "staging metadata: 'columns' must list at least one {source,target} mapping when sourceQuery is omitted."
    }
    $columnList = $Metadata['columns'] | ForEach-Object {
        $c = [hashtable]$_
        if (-not $c.ContainsKey('source')) { throw "staging metadata: every columns[] entry needs a 'source' field." }
        "[$($c['source'])]"
    }
    return "SELECT $($columnList -join ', ') FROM [$($src['schema'])].[$($src['table'])];"
}

function Resolve-PackageConnection {
    param([hashtable]$Metadata, [ValidateSet('source','target')][string]$Role)
    # Optional metadata block:  connections: { source: {server,database}, target: {server,database} }
    if ($Metadata.ContainsKey('connections') -and $Metadata['connections'].ContainsKey($Role)) {
        $c = [hashtable]$Metadata['connections'][$Role]
        return [PSCustomObject]@{ Server = $c['server']; Database = $c['database'] }
    }
    # Fallbacks from source/target blocks
    if ($Role -eq 'source' -and $Metadata.ContainsKey('source')) {
        $s = [hashtable]$Metadata['source']
        return [PSCustomObject]@{
            Server   = $(if ($s.ContainsKey('server')) { $s['server'] } else { '.\SQL2025' })
            Database = $(if ($s.ContainsKey('database')) { $s['database'] } else { 'AdventureWorks2025' })
        }
    }
    if ($Role -eq 'target' -and $Metadata.ContainsKey('target')) {
        $t = [hashtable]$Metadata['target']
        return [PSCustomObject]@{
            Server   = $(if ($t.ContainsKey('server')) { $t['server'] } else { '.\SQL2025' })
            Database = $(if ($t.ContainsKey('database')) { $t['database'] } else { 'CopilotSSIS_Warehouse' })
        }
    }
    throw "Cannot resolve $Role connection. Provide either connections.$Role.{server,database} or $Role.{database}."
}

Export-ModuleMember -Function New-StagingPackage
