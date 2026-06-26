# Type1Dimension.psm1 — implements the documented "type1-dim" pattern.
#
# Control flow (from .github/skills/ssis-package-patterns/SKILL.md):
#   DFT
#     OLE_SRC (read from stg.<Name>)
#     -> Lookup against dim.<Name> on businessKey, returning surrogateKey
#     -> Lookup No-Match Output  -> OLE_DST (insert new row into dim.<Name>)
#     -> Lookup Match    Output  -> OLE_DB_CMD UPDATE payload + LoadedAt WHERE surrogateKey = ?

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\SsisOm.psm1') -Force

function New-Type1DimensionPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Metadata,
        [Parameter(Mandatory)][string]$OutputPath
    )

    foreach ($req in 'packageName','sourceConnection','targetConnection','targetTable','businessKey','surrogateKey','payloadColumns') {
        if (-not $Metadata.ContainsKey($req)) { throw "type1-dim metadata: missing required field '$req'." }
    }
    if ($Metadata['businessKey'] -eq $Metadata['surrogateKey']) {
        throw "type1-dim metadata: businessKey and surrogateKey must differ."
    }
    $targetTable = $Metadata['targetTable']
    if (-not ($targetTable -match '^\[?dim\]?\.')) {
        throw "type1-dim metadata: targetTable '$targetTable' must be in the 'dim' schema."
    }
    $payload = @($Metadata['payloadColumns'])
    if ($payload.Count -eq 0) {
        throw "type1-dim metadata: payloadColumns must list at least one column."
    }

    $bk = $Metadata['businessKey']
    $sk = $Metadata['surrogateKey']

    $sourceQuery = Resolve-DimSourceQuery -Metadata $Metadata
    $cnSource = Resolve-DimConnection -Metadata $Metadata -Role 'source'
    $cnTarget = Resolve-DimConnection -Metadata $Metadata -Role 'target'

    $pkg = New-SsisPackage -Name $Metadata['packageName']
    $src = Add-OleDbConnection -Package $pkg -Name $Metadata['sourceConnection'] `
        -ServerName $cnSource.Server -InitialCatalog $cnSource.Database
    $tgt = Add-OleDbConnection -Package $pkg -Name $Metadata['targetConnection'] `
        -ServerName $cnTarget.Server -InitialCatalog $cnTarget.Database

    $dft = Add-DataFlowTask -Package $pkg -Name 'DFT Merge Dim'

    $oleSrc = Add-OleDbSource -DataFlow $dft -Name 'OLE_SRC Stg' `
        -Connection $src -SqlCommand $sourceQuery

    $lookupSql = "SELECT $sk, $bk FROM $targetTable;"
    $lkp = Add-Lookup -DataFlow $dft -Name 'LKP Dim' `
        -Connection $tgt -SqlCommand $lookupSql `
        -JoinColumns @{ $bk = $bk } `
        -ReturnColumns @($sk) `
        -NoMatchBehavior 'RedirectRow'
    Connect-DataFlowComponents -DataFlow $dft -From $oleSrc -To $lkp

    # No-match branch: insert new dim row
    $dstInsert = Add-OleDbDestination -DataFlow $dft -Name 'OLE_DST Insert' `
        -Connection $tgt -Table $targetTable
    Connect-DataFlowComponents -DataFlow $dft -From $lkp -To $dstInsert -FromOutputName 'Lookup No Match Output'
    Initialize-OleDbDestinationMapping -Destination $dstInsert

    # Match branch: OLE DB Command UPDATE payload + LoadedAt WHERE SK = ?
    $setClause = ($payload | ForEach-Object { "[$_] = ?" }) -join ', '
    $updateSql = "UPDATE $targetTable SET $setClause, LoadedAt = ? WHERE $sk = ?;"
    $cmd = Add-OleDbCommand -DataFlow $dft -Name 'CMD Update Payload' `
        -Connection $tgt -SqlCommand $updateSql
    Connect-DataFlowComponents -DataFlow $dft -From $lkp -To $cmd -FromOutputName 'Lookup Match Output'

    Save-SsisPackage -Package $pkg -Path $OutputPath
}

function Resolve-DimSourceQuery {
    param([hashtable]$Metadata)
    if ($Metadata.ContainsKey('sourceQuery') -and $Metadata['sourceQuery']) {
        return [string]$Metadata['sourceQuery']
    }
    if (-not $Metadata.ContainsKey('source')) {
        throw "dimension metadata: either 'sourceQuery' or 'source' (with schema/table) is required."
    }
    $src = [hashtable]$Metadata['source']
    foreach ($k in 'schema','table') {
        if (-not $src.ContainsKey($k)) { throw "dimension metadata: source.$k is required." }
    }
    if (-not $Metadata.ContainsKey('columns') -or $Metadata['columns'].Count -eq 0) {
        throw "dimension metadata: 'columns' must list at least one {source,target} mapping when sourceQuery is omitted."
    }
    $columnList = $Metadata['columns'] | ForEach-Object {
        $c = [hashtable]$_
        "[$($c['source'])]"
    }
    return "SELECT $($columnList -join ', ') FROM [$($src['schema'])].[$($src['table'])];"
}

function Resolve-DimConnection {
    param([hashtable]$Metadata, [ValidateSet('source','target')][string]$Role)
    if ($Metadata.ContainsKey('connections') -and $Metadata['connections'].ContainsKey($Role)) {
        $c = [hashtable]$Metadata['connections'][$Role]
        return [PSCustomObject]@{ Server = $c['server']; Database = $c['database'] }
    }
    if ($Role -eq 'source' -and $Metadata.ContainsKey('source')) {
        $s = [hashtable]$Metadata['source']
        return [PSCustomObject]@{
            Server   = $(if ($s.ContainsKey('server')) { $s['server'] } else { '.\SQL2025' })
            Database = $(if ($s.ContainsKey('database')) { $s['database'] } else { 'CopilotSSIS_Warehouse' })
        }
    }
    if ($Role -eq 'target' -and $Metadata.ContainsKey('target')) {
        $t = [hashtable]$Metadata['target']
        return [PSCustomObject]@{
            Server   = $(if ($t.ContainsKey('server')) { $t['server'] } else { '.\SQL2025' })
            Database = $(if ($t.ContainsKey('database')) { $t['database'] } else { 'CopilotSSIS_Warehouse' })
        }
    }
    throw "Cannot resolve $Role connection. Provide connections.$Role.{server,database} or $Role.{database}."
}

Export-ModuleMember -Function New-Type1DimensionPackage
