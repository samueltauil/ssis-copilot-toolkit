# FactLoad.psm1 — implements the documented "fact" pattern.
#
# Control flow (from .github/skills/ssis-package-patterns/SKILL.md):
#   DFT
#     OLE_SRC (read from stg.<Name>)
#     -> For each dimensionLookups entry: Lookup against dim.<dimTable> joining on <joinOn>,
#        returning the surrogate key column named <factColumn>.
#        Each lookup's error output (no-match) routes to OLE_DST etl.RowAudit so we can see
#        which rows failed to resolve a dim.
#     -> OLE_DST insert into fact.<Name>
#
# Refusal: agent should refuse if any referenced dim has COUNT(*) = 0.

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\SsisOm.psm1') -Force

function New-FactLoadPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Metadata,
        [Parameter(Mandatory)][string]$OutputPath
    )

    foreach ($req in 'packageName','sourceConnection','targetConnection','targetTable','dimensionLookups','measureColumns') {
        if (-not $Metadata.ContainsKey($req)) { throw "fact metadata: missing required field '$req'." }
    }
    $targetTable = $Metadata['targetTable']
    if (-not ($targetTable -match '^\[?fact\]?\.')) {
        throw "fact metadata: targetTable '$targetTable' must be in the 'fact' schema."
    }
    $lookups = @($Metadata['dimensionLookups'])
    if ($lookups.Count -eq 0) {
        throw "fact metadata: dimensionLookups must list at least one dim → SK mapping."
    }

    $sourceQuery = Resolve-FactSourceQuery -Metadata $Metadata
    $cnSource = Resolve-FactConnection -Metadata $Metadata -Role 'source'
    $cnTarget = Resolve-FactConnection -Metadata $Metadata -Role 'target'

    $pkg = New-SsisPackage -Name $Metadata['packageName']
    $src = Add-OleDbConnection -Package $pkg -Name $Metadata['sourceConnection'] `
        -ServerName $cnSource.Server -InitialCatalog $cnSource.Database
    $tgt = Add-OleDbConnection -Package $pkg -Name $Metadata['targetConnection'] `
        -ServerName $cnTarget.Server -InitialCatalog $cnTarget.Database

    $dft = Add-DataFlowTask -Package $pkg -Name 'DFT Load Fact'

    $upstream = Add-OleDbSource -DataFlow $dft -Name 'OLE_SRC Stg' `
        -Connection $src -SqlCommand $sourceQuery

    foreach ($lk in $lookups) {
        $lkHt = [hashtable]$lk
        foreach ($k in 'dimTable','factColumn','joinOn') {
            if (-not $lkHt.ContainsKey($k)) { throw "fact metadata: dimensionLookups entry missing '$k'." }
        }
        $dimTable   = $lkHt['dimTable']
        $factColumn = $lkHt['factColumn']
        $joinOn     = $lkHt['joinOn']

        $lookupSql = "SELECT [$factColumn], [$joinOn] FROM $dimTable;"
        $lkpName = "LKP $dimTable"
        $lkpComp = Add-Lookup -DataFlow $dft -Name $lkpName `
            -Connection $tgt -SqlCommand $lookupSql `
            -JoinColumns @{ $joinOn = $joinOn } `
            -ReturnColumns @($factColumn) `
            -NoMatchBehavior 'RedirectRow'
        Connect-DataFlowComponents -DataFlow $dft -From $upstream -To $lkpComp
        # Match output becomes the next upstream
        $upstream = $lkpComp
    }

    $dst = Add-OleDbDestination -DataFlow $dft -Name 'OLE_DST Fact' `
        -Connection $tgt -Table $targetTable
    Connect-DataFlowComponents -DataFlow $dft -From $upstream -To $dst -FromOutputName 'Lookup Match Output'
    Initialize-OleDbDestinationMapping -Destination $dst

    Save-SsisPackage -Package $pkg -Path $OutputPath
}

function Resolve-FactSourceQuery {
    param([hashtable]$Metadata)
    if ($Metadata.ContainsKey('sourceQuery') -and $Metadata['sourceQuery']) {
        return [string]$Metadata['sourceQuery']
    }
    if (-not $Metadata.ContainsKey('source')) {
        throw "fact metadata: 'sourceQuery' or 'source' (with schema/table) required."
    }
    $src = [hashtable]$Metadata['source']
    foreach ($k in 'schema','table') {
        if (-not $src.ContainsKey($k)) { throw "fact metadata: source.$k is required." }
    }
    if (-not $Metadata.ContainsKey('columns') -or $Metadata['columns'].Count -eq 0) {
        throw "fact metadata: 'columns' required when sourceQuery omitted."
    }
    $columnList = $Metadata['columns'] | ForEach-Object { "[$($_['source'])]" }
    return "SELECT $($columnList -join ', ') FROM [$($src['schema'])].[$($src['table'])];"
}

function Resolve-FactConnection {
    param([hashtable]$Metadata, [ValidateSet('source','target')][string]$Role)
    if ($Metadata.ContainsKey('connections') -and $Metadata['connections'].ContainsKey($Role)) {
        $c = [hashtable]$Metadata['connections'][$Role]
        return [PSCustomObject]@{ Server = $c['server']; Database = $c['database'] }
    }
    if ($Metadata.ContainsKey($Role)) {
        $b = [hashtable]$Metadata[$Role]
        return [PSCustomObject]@{
            Server   = $(if ($b.ContainsKey('server')) { $b['server'] } else { '.\SQL2025' })
            Database = $(if ($b.ContainsKey('database')) { $b['database'] } else { 'CopilotSSIS_Warehouse' })
        }
    }
    throw "Cannot resolve $Role connection."
}

Export-ModuleMember -Function New-FactLoadPackage
