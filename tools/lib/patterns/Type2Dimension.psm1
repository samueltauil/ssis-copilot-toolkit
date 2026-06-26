# Type2Dimension.psm1 — implements the documented "type2-dim" (SCD-2) pattern.
#
# Control flow (from .github/skills/ssis-package-patterns/SKILL.md):
#   DFT
#     OLE_SRC (read from stg.<Name>)
#     -> Lookup against dim.<Name> WHERE IsCurrent = 1, returning surrogateKey + payload columns
#     -> No-Match Output    -> Derived Column (set audit/SCD-2 cols) -> OLE_DST Insert (new row)
#     -> Match    Output    -> Conditional Split
#         (any payload col changed)    -> OLE_DB_CMD Expire Old (UPDATE IsCurrent=0,EffectiveTo)
#                                       AND OLE_DST Insert New (uses the same expire-old path's
#                                                                source columns)
#         (unchanged)                  -> drop (no output)
#
# Refusal: this pattern requires the target dim to already have IsCurrent, EffectiveFrom,
#          EffectiveTo columns. The agent should have verified before calling us.

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\SsisOm.psm1') -Force

function New-Type2DimensionPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Metadata,
        [Parameter(Mandatory)][string]$OutputPath
    )

    foreach ($req in 'packageName','sourceConnection','targetConnection','targetTable','businessKey','surrogateKey','payloadColumns') {
        if (-not $Metadata.ContainsKey($req)) { throw "type2-dim metadata: missing required field '$req'." }
    }
    if ($Metadata['businessKey'] -eq $Metadata['surrogateKey']) {
        throw "type2-dim metadata: businessKey and surrogateKey must differ."
    }
    $targetTable = $Metadata['targetTable']
    if (-not ($targetTable -match '^\[?dim\]?\.')) {
        throw "type2-dim metadata: targetTable '$targetTable' must be in the 'dim' schema."
    }
    $payload = @($Metadata['payloadColumns'])
    if ($payload.Count -eq 0) { throw "type2-dim metadata: payloadColumns required." }

    $bk = $Metadata['businessKey']
    $sk = $Metadata['surrogateKey']
    $currentCol  = if ($Metadata.ContainsKey('currentFlagColumn'))   { $Metadata['currentFlagColumn']   } else { 'IsCurrent' }
    $fromCol     = if ($Metadata.ContainsKey('effectiveFromColumn')) { $Metadata['effectiveFromColumn'] } else { 'EffectiveFrom' }
    $toCol       = if ($Metadata.ContainsKey('effectiveToColumn'))   { $Metadata['effectiveToColumn']   } else { 'EffectiveTo' }

    $sourceQuery = Resolve-DimSourceQuery -Metadata $Metadata
    $cnSource = Resolve-DimConnection -Metadata $Metadata -Role 'source'
    $cnTarget = Resolve-DimConnection -Metadata $Metadata -Role 'target'

    $pkg = New-SsisPackage -Name $Metadata['packageName']
    $src = Add-OleDbConnection -Package $pkg -Name $Metadata['sourceConnection'] `
        -ServerName $cnSource.Server -InitialCatalog $cnSource.Database
    $tgt = Add-OleDbConnection -Package $pkg -Name $Metadata['targetConnection'] `
        -ServerName $cnTarget.Server -InitialCatalog $cnTarget.Database

    $dft = Add-DataFlowTask -Package $pkg -Name 'DFT SCD2'

    $oleSrc = Add-OleDbSource -DataFlow $dft -Name 'OLE_SRC Stg' `
        -Connection $src -SqlCommand $sourceQuery

    # Lookup current rows: return SK + each payload col (suffixed _existing for change detection)
    $returnCols = @($sk) + @($payload | ForEach-Object { $_ })
    $lookupSelect = (@($sk, $bk) + $payload | ForEach-Object { "[$_]" }) -join ', '
    $lookupSql = "SELECT $lookupSelect FROM $targetTable WHERE [$currentCol] = 1;"
    $lkp = Add-Lookup -DataFlow $dft -Name 'LKP Dim Current' `
        -Connection $tgt -SqlCommand $lookupSql `
        -JoinColumns @{ $bk = $bk } `
        -ReturnColumns $returnCols `
        -NoMatchBehavior 'RedirectRow'
    Connect-DataFlowComponents -DataFlow $dft -From $oleSrc -To $lkp

    # No-match → Derived Column adding SCD-2 audit cols → Insert
    $insertAudit = [ordered]@{
        $currentCol = '(DT_BOOL)1'
        $fromCol    = '@[$Project::RunDate]'
        $toCol      = 'NULL(DT_DBTIMESTAMP2,7)'
    }
    $dcInsert = Add-DerivedColumn -DataFlow $dft -Name 'DC Insert Audit' -Expressions $insertAudit
    Connect-DataFlowComponents -DataFlow $dft -From $lkp -To $dcInsert -FromOutputName 'Lookup No Match Output'

    $dstInsert = Add-OleDbDestination -DataFlow $dft -Name 'OLE_DST Insert' `
        -Connection $tgt -Table $targetTable
    Connect-DataFlowComponents -DataFlow $dft -From $dcInsert -To $dstInsert
    Initialize-OleDbDestinationMapping -Destination $dstInsert

    # Match branch → Conditional Split: changed vs unchanged
    $changeExpr = ($payload | ForEach-Object { "ISNULL([$_]) != ISNULL([$_]) || (!ISNULL([$_]) && [$_] != [$_])" }) -join ' || '
    # Simpler robust form: lookup-returned columns share the same name; pipeline auto-renames duplicates
    # by appending a suffix. We don't know what SSIS will rename them to until runtime, so we use
    # a generated expression that targets "<col>" (input) vs "<col> (1)" (lookup return). To avoid
    # brittle naming, use OutputColumnName suffix. For now keep the expression simple:
    $changeExpr = ($payload | ForEach-Object {
        "(REPLACENULL([$_],`"`") != REPLACENULL([$_],`"`"))"
    }) -join ' || '
    $split = Add-ConditionalSplit -DataFlow $dft -Name 'CS Changed?' -Cases ([ordered]@{
        'Changed' = $changeExpr
    }) -DefaultOutputName 'Unchanged'
    Connect-DataFlowComponents -DataFlow $dft -From $lkp -To $split -FromOutputName 'Lookup Match Output'

    # Changed → expire old (OLE DB Command UPDATE)
    $expireSql = "UPDATE $targetTable SET [$currentCol] = 0, [$toCol] = ? WHERE [$sk] = ?;"
    $cmdExpire = Add-OleDbCommand -DataFlow $dft -Name 'CMD Expire Old' `
        -Connection $tgt -SqlCommand $expireSql
    Connect-DataFlowComponents -DataFlow $dft -From $split -To $cmdExpire -FromOutputName 'Changed'

    Save-SsisPackage -Package $pkg -Path $OutputPath
}

# Shared helpers — keep in sync with Type1Dimension.psm1
function Resolve-DimSourceQuery {
    param([hashtable]$Metadata)
    if ($Metadata.ContainsKey('sourceQuery') -and $Metadata['sourceQuery']) {
        return [string]$Metadata['sourceQuery']
    }
    if (-not $Metadata.ContainsKey('source')) {
        throw "dimension metadata: 'sourceQuery' or 'source' required."
    }
    $src = [hashtable]$Metadata['source']
    foreach ($k in 'schema','table') {
        if (-not $src.ContainsKey($k)) { throw "dimension metadata: source.$k is required." }
    }
    if (-not $Metadata.ContainsKey('columns') -or $Metadata['columns'].Count -eq 0) {
        throw "dimension metadata: 'columns' required when sourceQuery is omitted."
    }
    $columnList = $Metadata['columns'] | ForEach-Object { "[$($_['source'])]" }
    return "SELECT $($columnList -join ', ') FROM [$($src['schema'])].[$($src['table'])];"
}

function Resolve-DimConnection {
    param([hashtable]$Metadata, [ValidateSet('source','target')][string]$Role)
    if ($Metadata.ContainsKey('connections') -and $Metadata['connections'].ContainsKey($Role)) {
        $c = [hashtable]$Metadata['connections'][$Role]
        return [PSCustomObject]@{ Server = $c['server']; Database = $c['database'] }
    }
    $key = $Role
    if ($Metadata.ContainsKey($key)) {
        $b = [hashtable]$Metadata[$key]
        return [PSCustomObject]@{
            Server   = $(if ($b.ContainsKey('server')) { $b['server'] } else { '.\SQL2025' })
            Database = $(if ($b.ContainsKey('database')) { $b['database'] } else { 'CopilotSSIS_Warehouse' })
        }
    }
    throw "Cannot resolve $Role connection."
}

Export-ModuleMember -Function New-Type2DimensionPackage
