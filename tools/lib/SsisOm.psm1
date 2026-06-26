# SsisOm.psm1 — thin wrapper over the SSIS managed object model (Microsoft.SqlServer.Dts.Runtime).
# Helper names match the documented contract in .github/skills/ssis-package-patterns/SKILL.md.
# These are the ONLY public helpers pattern modules under tools/lib/patterns/ should call.
# Pattern modules NEVER touch the .dtsx XML directly — they call into here.

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Import-SsisAssemblies {
    [CmdletBinding()]
    param()
    if (([System.Management.Automation.PSTypeName]'Microsoft.SqlServer.Dts.Runtime.Application').Type) { return }

    # SQL Server 2025 (v170) deploys SSIS managed assemblies to the GAC. Two
    # of them — DTSRuntimeWrap and DTSPipelineWrap — are COM interop wrappers
    # with architecture-specific copies in GAC_64 / GAC_32 (NOT GAC_MSIL).
    # The GAC_64 copies are richer than the redistributable copies that ship
    # with Visual Studio's SSIS Projects extension; only the GAC copies expose
    # the IDTSApplication170 / pipeline interop interfaces ManagedDTS needs.
    #
    # ProvideComponentProperties() is a native COM call into a pipeline
    # component DLL (e.g. OleDbSrc.dll), which implicitly depends on
    # DtsConn.dll, DTSPipeline.dll, dtsmsg170.dll, MSDtsSrvrUtil.dll, etc.
    # When PowerShell hosts these, the loader can't find those siblings
    # unless they're on PATH — producing TYPE_E_ELEMENTNOTFOUND. We fix that
    # by prepending the SQL Server DTS\Binn and PipelineComponents folders
    # to PATH before loading anything.

    $binn = 'C:\Program Files\Microsoft SQL Server\170\DTS\Binn'
    $pipe = 'C:\Program Files\Microsoft SQL Server\170\DTS\PipelineComponents'
    if (-not (Test-Path $binn)) { $binn = 'C:\Program Files\Microsoft SQL Server\160\DTS\Binn' }
    if (-not (Test-Path $pipe)) { $pipe = 'C:\Program Files\Microsoft SQL Server\160\DTS\PipelineComponents' }
    foreach ($p in @($binn, $pipe)) {
        if ((Test-Path $p) -and ($env:PATH -notlike "*$p*")) { $env:PATH = "$p;$env:PATH" }
    }

    $needed = @(
        'Microsoft.SqlServer.ManagedDTS'
        'Microsoft.SqlServer.DTSPipelineWrap'
        'Microsoft.SqlServer.DTSRuntimeWrap'
        'Microsoft.SqlServer.PipelineHost'
    )
    $gacRoots = @(
        'C:\Windows\Microsoft.NET\assembly\GAC_64'
        'C:\Windows\Microsoft.NET\assembly\GAC_MSIL'
        'C:\Windows\Microsoft.NET\assembly\GAC_32'
    )
    $loaded = @{}
    foreach ($name in $needed) {
        $candidates = @()
        foreach ($root in $gacRoots) {
            $dir = Join-Path $root $name
            if (Test-Path $dir) {
                Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    Get-ChildItem -LiteralPath $_.FullName -Filter "$name.dll" -File -ErrorAction SilentlyContinue |
                        ForEach-Object { $candidates += $_.FullName }
                }
            }
        }
        # Fallback: DTS\Binn
        $binnDll = Join-Path $binn "$name.dll"
        if (Test-Path $binnDll) { $candidates += $binnDll }
        if ($candidates.Count -eq 0) {
            if ($name -eq 'Microsoft.SqlServer.ManagedDTS') {
                throw "$name.dll not found in GAC or $binn"
            }
            continue
        }
        # Prefer v17 over v13 by sorting on parent folder name desc.
        $chosen = $candidates | Sort-Object { Split-Path -Parent $_ } -Descending | Select-Object -First 1
        $loaded[$name] = $chosen
        [void][System.Reflection.Assembly]::LoadFrom($chosen)
    }
    Write-Verbose ("Loaded: " + (($loaded.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '))
}

function New-SsisPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('DontSaveSensitive','EncryptSensitiveWithUserKey','EncryptSensitiveWithPassword','EncryptAllWithUserKey','EncryptAllWithPassword','ServerStorage')]
        [string]$ProtectionLevel = 'DontSaveSensitive'
    )
    Import-SsisAssemblies
    $pkg = New-Object Microsoft.SqlServer.Dts.Runtime.Package
    $pkg.Name = $Name
    $pkg.ProtectionLevel = [Microsoft.SqlServer.Dts.Runtime.DTSProtectionLevel]::$ProtectionLevel
    return $pkg
}

function Add-OleDbConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$InitialCatalog,
        [switch]$DisableIntegratedSecurity
    )
    $cm = $Package.Connections.Add('OLEDB')
    $cm.Name = $Name
    $integrated = if ($DisableIntegratedSecurity) { 'False' } else { 'SSPI' }
    $cm.ConnectionString = "Data Source=$ServerName;Initial Catalog=$InitialCatalog;Provider=MSOLEDBSQL;Integrated Security=$integrated;Auto Translate=False;"
    return $cm
}

function Add-ExecuteSqlTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$SqlStatement
    )
    $exec = $Package.Executables.Add('Microsoft.ExecuteSQLTask')
    $exec.Name = $Name
    $task = $exec.InnerObject
    $task.Connection = $Connection.Name
    $task.SqlStatementSource = $SqlStatement
    return $exec
}

function Add-DataFlowTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$Name
    )
    $exec = $Package.Executables.Add('Microsoft.Pipeline')
    $exec.Name = $Name
    $mainPipe = $exec.InnerObject
    return [PSCustomObject]@{
        TaskHost = $exec
        MainPipe = $mainPipe
    }
}

function Set-ComponentConnection {
    # Internal: bind a pipeline component's first runtime connection to a package connection manager.
    [CmdletBinding()]
    param($Component, $Connection)
    $Component.RuntimeConnectionCollection[0].ConnectionManagerID = $Connection.ID
    $Component.RuntimeConnectionCollection[0].ConnectionManager = `
        [Microsoft.SqlServer.Dts.Runtime.DtsConvert]::GetExtendedInterface($Connection)
}

function Add-OleDbSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DataFlow,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$SqlCommand
    )
    $comp = $DataFlow.MainPipe.ComponentMetaDataCollection.New()
    $comp.Name = $Name
    $comp.ComponentClassID = 'Microsoft.OLEDBSource'
    $instance = $comp.Instantiate()
    $instance.ProvideComponentProperties()
    Set-ComponentConnection -Component $comp -Connection $Connection
    $comp.CustomPropertyCollection['AccessMode'].Value = 2     # SqlCommand
    $comp.CustomPropertyCollection['SqlCommand'].Value = $SqlCommand
    $instance.AcquireConnections($null)
    $instance.ReinitializeMetaData()
    $instance.ReleaseConnections()
    return $comp
}

function Add-OleDbDestination {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DataFlow,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Table,
        [switch]$DisableFastLoad,
        [int]$RowsPerBatch = 10000
    )
    $comp = $DataFlow.MainPipe.ComponentMetaDataCollection.New()
    $comp.Name = $Name
    $comp.ComponentClassID = 'Microsoft.OLEDBDestination'
    $instance = $comp.Instantiate()
    $instance.ProvideComponentProperties()
    Set-ComponentConnection -Component $comp -Connection $Connection
    $accessMode = if ($DisableFastLoad) { 0 } else { 3 }  # 3 = OpenRowsetUsingFastLoad
    $comp.CustomPropertyCollection['AccessMode'].Value = $accessMode
    $comp.CustomPropertyCollection['OpenRowset'].Value = $Table
    if (-not $DisableFastLoad) {
        $comp.CustomPropertyCollection['FastLoadOptions'].Value = 'TABLOCK,CHECK_CONSTRAINTS'
        $comp.CustomPropertyCollection['FastLoadMaxInsertCommitSize'].Value = $RowsPerBatch
    }
    return $comp
}

function Add-DerivedColumn {
    # Expressions: hashtable of @{ OutColumnName = 'SSIS expression string' }
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DataFlow,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Expressions
    )
    $comp = $DataFlow.MainPipe.ComponentMetaDataCollection.New()
    $comp.Name = $Name
    $comp.ComponentClassID = 'Microsoft.DerivedColumn'
    $instance = $comp.Instantiate()
    $instance.ProvideComponentProperties()
    $output = $comp.OutputCollection[0]
    foreach ($outName in $Expressions.Keys) {
        $newCol = $output.OutputColumnCollection.New()
        $newCol.Name = $outName
        $newCol.SetDataTypeProperties([Microsoft.SqlServer.Dts.Runtime.Wrapper.DataType]::DT_DBTIMESTAMP, 0, 0, 0, 0)
        $expr = $Expressions[$outName]
        $newCol.CustomPropertyCollection['Expression'].Value = $expr
        $newCol.CustomPropertyCollection['FriendlyExpression'].Value = $expr
    }
    return $comp
}

function Add-Lookup {
    # JoinColumns: @{ inputColumnName = 'lookupColumnName' }
    # ReturnColumns: array of lookup column names to expose downstream
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DataFlow,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$SqlCommand,
        [Parameter(Mandatory)][hashtable]$JoinColumns,
        [string[]]$ReturnColumns = @(),
        [ValidateSet('FailComponent','IgnoreFailure','RedirectRow')]
        [string]$NoMatchBehavior = 'RedirectRow'
    )
    $comp = $DataFlow.MainPipe.ComponentMetaDataCollection.New()
    $comp.Name = $Name
    $comp.ComponentClassID = 'Microsoft.Lookup'
    $instance = $comp.Instantiate()
    $instance.ProvideComponentProperties()
    Set-ComponentConnection -Component $comp -Connection $Connection
    $comp.CustomPropertyCollection['SqlCommand'].Value = $SqlCommand
    $comp.CustomPropertyCollection['CacheType'].Value = 1     # Partial
    switch ($NoMatchBehavior) {
        'FailComponent'  { $comp.CustomPropertyCollection['NoMatchBehavior'].Value = 0 }
        'IgnoreFailure'  { $comp.CustomPropertyCollection['NoMatchBehavior'].Value = 1 }
        'RedirectRow'    { $comp.CustomPropertyCollection['NoMatchBehavior'].Value = 2 }
    }
    $instance.AcquireConnections($null)
    $instance.ReinitializeMetaData()
    $instance.ReleaseConnections()

    $inputObj = $comp.InputCollection[0]
    $virtualInput = $inputObj.GetVirtualInput()
    $lookupExternal = $comp.InputCollection[0].ExternalMetadataColumnCollection
    foreach ($inputColName in $JoinColumns.Keys) {
        $inputCol = $virtualInput.VirtualInputColumnCollection | Where-Object { $_.Name -eq $inputColName } | Select-Object -First 1
        if (-not $inputCol) { throw "Lookup '$Name': input column '$inputColName' not found upstream." }
        $instance.SetUsageType($inputObj.ID, $virtualInput, $inputCol.LineageID, [Microsoft.SqlServer.Dts.Pipeline.Wrapper.DTSUsageType]::UT_READONLY)
        $matchedInput = $inputObj.InputColumnCollection | Where-Object { $_.LineageID -eq $inputCol.LineageID } | Select-Object -First 1
        $lookupColName = $JoinColumns[$inputColName]
        $external = $lookupExternal | Where-Object { $_.Name -eq $lookupColName } | Select-Object -First 1
        if (-not $external) { throw "Lookup '$Name': lookup column '$lookupColName' not found in target table." }
        $matchedInput.CustomPropertyCollection['JoinToReferenceColumn'].Value = $lookupColName
    }
    if ($ReturnColumns.Count -gt 0) {
        $matchOutput = $comp.OutputCollection['Lookup Match Output']
        foreach ($returnName in $ReturnColumns) {
            $external = $lookupExternal | Where-Object { $_.Name -eq $returnName } | Select-Object -First 1
            if (-not $external) { throw "Lookup '$Name': return column '$returnName' not found in target table." }
            $newOutCol = $matchOutput.OutputColumnCollection.New()
            $newOutCol.Name = $returnName
            $newOutCol.SetDataTypeProperties($external.DataType, $external.Length, $external.Precision, $external.Scale, $external.CodePage)
            $newOutCol.CustomPropertyCollection['CopyFromReferenceColumn'].Value = $returnName
        }
    }
    return $comp
}

function Add-ConditionalSplit {
    # Cases: ordered hashtable of @{ OutputName = 'SSIS expression returning bool' }
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DataFlow,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Cases,
        [string]$DefaultOutputName = 'Default'
    )
    $comp = $DataFlow.MainPipe.ComponentMetaDataCollection.New()
    $comp.Name = $Name
    $comp.ComponentClassID = 'Microsoft.ConditionalSplit'
    $instance = $comp.Instantiate()
    $instance.ProvideComponentProperties()
    foreach ($caseName in $Cases.Keys) {
        $newOut = $comp.OutputCollection.New()
        $newOut.Name = $caseName
        $newOut.IsErrorOut = $false
        $newOut.SynchronousInputID = $comp.InputCollection[0].ID
        $expr = $Cases[$caseName]
        $newOut.CustomPropertyCollection['Expression'].Value = $expr
        $newOut.CustomPropertyCollection['FriendlyExpression'].Value = $expr
        $newOut.CustomPropertyCollection['EvaluationOrder'].Value = $comp.OutputCollection.Count - 1
    }
    $defaultOut = $comp.OutputCollection[0]
    $defaultOut.Name = $DefaultOutputName
    return $comp
}

function Add-OleDbCommand {
    # SqlCommand may contain `?` placeholders. Parameter mapping is left to the caller via
    # comp.InputCollection[0].InputColumnCollection[i].CustomPropertyCollection['ColumnName'].
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DataFlow,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$SqlCommand
    )
    $comp = $DataFlow.MainPipe.ComponentMetaDataCollection.New()
    $comp.Name = $Name
    $comp.ComponentClassID = 'Microsoft.OleDbCommand'
    $instance = $comp.Instantiate()
    $instance.ProvideComponentProperties()
    Set-ComponentConnection -Component $comp -Connection $Connection
    $comp.CustomPropertyCollection['SqlCommand'].Value = $SqlCommand
    $instance.AcquireConnections($null)
    $instance.ReinitializeMetaData()
    $instance.ReleaseConnections()
    return $comp
}

function Connect-DataFlowComponents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DataFlow,
        [Parameter(Mandatory)]$From,
        [Parameter(Mandatory)]$To,
        [string]$FromOutputName,
        [string]$ToInputName
    )
    $output = if ($FromOutputName) {
        $From.OutputCollection | Where-Object { $_.Name -eq $FromOutputName } | Select-Object -First 1
    } else {
        $From.OutputCollection | Where-Object { -not $_.IsErrorOut } | Select-Object -First 1
    }
    if (-not $output) { throw "Connect: output '$FromOutputName' not found on '$($From.Name)'." }
    $inputObj = if ($ToInputName) {
        $To.InputCollection | Where-Object { $_.Name -eq $ToInputName } | Select-Object -First 1
    } else {
        $To.InputCollection[0]
    }
    if (-not $inputObj) { throw "Connect: input '$ToInputName' not found on '$($To.Name)'." }
    $path = $DataFlow.MainPipe.PathCollection.New()
    $path.AttachPathAndPropagateNotifications($output, $inputObj)
}

function Initialize-OleDbDestinationMapping {
    # Auto-map upstream input columns to destination external columns by name.
    # Call AFTER Connect-DataFlowComponents so input metadata is populated.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Destination
    )
    $instance = $Destination.Instantiate()
    $instance.AcquireConnections($null)
    $instance.ReinitializeMetaData()
    $instance.ReleaseConnections()
    $inputObj = $Destination.InputCollection[0]
    $virtualInput = $inputObj.GetVirtualInput()
    foreach ($vCol in $virtualInput.VirtualInputColumnCollection) {
        $external = $inputObj.ExternalMetadataColumnCollection | Where-Object { $_.Name -eq $vCol.Name } | Select-Object -First 1
        if (-not $external) { continue }   # skip unmapped (e.g. identity columns)
        $instance.SetUsageType($inputObj.ID, $virtualInput, $vCol.LineageID, [Microsoft.SqlServer.Dts.Pipeline.Wrapper.DTSUsageType]::UT_READONLY)
        $matched = $inputObj.InputColumnCollection | Where-Object { $_.LineageID -eq $vCol.LineageID } | Select-Object -First 1
        if ($matched) { $matched.ExternalMetadataColumnID = $external.ID }
    }
}

function Save-SsisPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$Path
    )
    Import-SsisAssemblies
    $app = New-Object Microsoft.SqlServer.Dts.Runtime.Application
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $app.SaveToXml($Path, $Package, $null)
}

function Read-SsisPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    Import-SsisAssemblies
    $app = New-Object Microsoft.SqlServer.Dts.Runtime.Application
    return $app.LoadPackage($Path, $null)
}

Export-ModuleMember -Function `
    Import-SsisAssemblies, `
    New-SsisPackage, `
    Add-OleDbConnection, `
    Add-ExecuteSqlTask, `
    Add-DataFlowTask, `
    Add-OleDbSource, `
    Add-OleDbDestination, `
    Add-DerivedColumn, `
    Add-Lookup, `
    Add-ConditionalSplit, `
    Add-OleDbCommand, `
    Connect-DataFlowComponents, `
    Initialize-OleDbDestinationMapping, `
    Save-SsisPackage, `
    Read-SsisPackage
