<#
.SYNOPSIS
    Generates an SSIS .dtproj file and connection manager .conmgr files from a template.

.DESCRIPTION
    Creates the required .dtproj and .conmgr XML files that Visual Studio needs to
    open and execute SSIS packages. Scans the Packages folder for all .dtsx files
    and registers them in the project.

    - Sets ProtectionLevel to DontSaveSensitive (per repo rules)
    - Creates project-level connection managers for AdventureWorks2025 and CopilotSSIS_Warehouse
    - Generates the .params file for project parameters
    - All XML is well-formed and ready for Visual Studio Designer

.PARAMETER ProjectPath
    Path to the SSIS project folder containing the Packages subfolder.
    Defaults to templates/ssis-project.

.PARAMETER ProjectName
    Name of the SSIS project. Defaults to "CopilotSsisDemos".

.PARAMETER SourceServer
    SQL Server instance for AdventureWorks2025 source.
    Defaults to "localhost\SQL2025".

.PARAMETER TargetServer
    SQL Server instance for CopilotSSIS_Warehouse target.
    Defaults to "localhost\SQL2025".

.EXAMPLE
    .\tools\New-SsisProject.ps1
    Generates the .dtproj and .conmgr files in templates/ssis-project with default settings.

.EXAMPLE
    .\tools\New-SsisProject.ps1 -ProjectPath "MySsisProject" -ProjectName "MyProject"
    Generates files for a custom project location and name.

.NOTES
    Primitive script — does one thing. Called by @ssis-author when scaffolding a project.
    Never hand-edit the generated .dtproj, .conmgr, or .params files; regenerate via this script.
#>

[CmdletBinding()]
param(
    [string]$ProjectPath = 'templates/ssis-project',
    [string]$ProjectName = 'CopilotSsisDemos',
    [string]$SourceServer = 'localhost\SQL2025',
    [string]$TargetServer = 'localhost\SQL2025'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve project path
$projectDir = if ([System.IO.Path]::IsPathRooted($ProjectPath)) {
    $ProjectPath
} else {
    Join-Path $PSScriptRoot "..\$ProjectPath"
}

if (-not (Test-Path $projectDir)) {
    throw "Project directory not found: $projectDir"
}

# Flat structure: all files (packages, connection managers) sit alongside .dtproj
$connMgrDir = $projectDir

Write-Host "Generating SSIS project files in: $projectDir" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Generate connection manager files (.conmgr)
# ---------------------------------------------------------------------------

$sourceConnMgrPath = Join-Path $connMgrDir 'AdventureWorks2025.conmgr'
$sourceConnMgrXml = @"
<?xml version="1.0"?>
<DTS:ConnectionManager xmlns:DTS="www.microsoft.com/SqlServer/Dts"
  DTS:ObjectName="AdventureWorks2025"
  DTS:DTSID="{$(New-Guid)}"
  DTS:CreationName="OLEDB">
  <DTS:ObjectData>
    <DTS:ConnectionManager
      DTS:ConnectionString="Data Source=$SourceServer;Initial Catalog=AdventureWorks2025;Provider=SQLOLEDB.1;Integrated Security=SSPI;Application Name=SSIS-CopilotSsisDemos;Auto Translate=False;" />
  </DTS:ObjectData>
  <DTS:Property DTS:Name="ProtectionLevel">0</DTS:Property>
</DTS:ConnectionManager>
"@

$targetConnMgrPath = Join-Path $connMgrDir 'CopilotSSIS_Warehouse.conmgr'
$targetConnMgrXml = @"
<?xml version="1.0"?>
<DTS:ConnectionManager xmlns:DTS="www.microsoft.com/SqlServer/Dts"
  DTS:ObjectName="CopilotSSIS_Warehouse"
  DTS:DTSID="{$(New-Guid)}"
  DTS:CreationName="OLEDB">
  <DTS:ObjectData>
    <DTS:ConnectionManager
      DTS:ConnectionString="Data Source=$TargetServer;Initial Catalog=CopilotSSIS_Warehouse;Provider=SQLOLEDB.1;Integrated Security=SSPI;Application Name=SSIS-CopilotSsisDemos;Auto Translate=False;" />
  </DTS:ObjectData>
  <DTS:Property DTS:Name="ProtectionLevel">0</DTS:Property>
</DTS:ConnectionManager>
"@

Write-Host "  Creating $sourceConnMgrPath" -ForegroundColor Gray
[System.IO.File]::WriteAllText($sourceConnMgrPath, $sourceConnMgrXml, [System.Text.Encoding]::UTF8)

Write-Host "  Creating $targetConnMgrPath" -ForegroundColor Gray
[System.IO.File]::WriteAllText($targetConnMgrPath, $targetConnMgrXml, [System.Text.Encoding]::UTF8)

# ---------------------------------------------------------------------------
# 2. Scan for .dtsx packages
# ---------------------------------------------------------------------------

$packages = @(Get-ChildItem -Path $projectDir -Filter '*.dtsx' -File |
    Where-Object { $_.Name -notlike '.gitkeep' } |
    Sort-Object Name)

if ($packages.Count -eq 0) {
    Write-Warning "No .dtsx packages found in $projectDir"
}

Write-Host "  Found $($packages.Count) package(s)" -ForegroundColor Gray

# ---------------------------------------------------------------------------
# 3. Generate .dtproj file
# ---------------------------------------------------------------------------

$dtprojPath = Join-Path $projectDir "$ProjectName.dtproj"
$projectGuid = New-Guid
$paramsGuid = New-Guid

# Build SSIS:Package entries (correct manifest schema)
$packageItems = @()
foreach ($pkg in $packages) {
    $packageItems += "          <SSIS:Package SSIS:Name=`"$($pkg.Name)`" SSIS:EntryPoint=`"1`" />"
}

# Build SSIS:ConnectionManager entries
$connMgrItems = @()
$connMgrItems += "          <SSIS:ConnectionManager SSIS:Name=`"AdventureWorks2025.conmgr`" />"
$connMgrItems += "          <SSIS:ConnectionManager SSIS:Name=`"CopilotSSIS_Warehouse.conmgr`" />"

# Build PackageMetaData entries before the main here-string
$packageMetaDataEntries = $packages | ForEach-Object {
    $pkgId = New-Guid
    $versionGuid = New-Guid
    @"
            <SSIS:PackageMetaData SSIS:Name="$($_.Name)">
              <SSIS:Properties>
                <SSIS:Property SSIS:Name="ID">{$pkgId}</SSIS:Property>
                <SSIS:Property SSIS:Name="Name">$($_.BaseName)</SSIS:Property>
                <SSIS:Property SSIS:Name="VersionMajor">1</SSIS:Property>
                <SSIS:Property SSIS:Name="VersionMinor">0</SSIS:Property>
                <SSIS:Property SSIS:Name="VersionBuild">0</SSIS:Property>
                <SSIS:Property SSIS:Name="VersionComments">
                </SSIS:Property>
                <SSIS:Property SSIS:Name="VersionGUID">{$versionGuid}</SSIS:Property>
                <SSIS:Property SSIS:Name="PackageFormatVersion">8</SSIS:Property>
                <SSIS:Property SSIS:Name="Description">
                </SSIS:Property>
                <SSIS:Property SSIS:Name="ProtectionLevel">0</SSIS:Property>
              </SSIS:Properties>
              <SSIS:Parameters />
            </SSIS:PackageMetaData>
"@
}
$packageMetaDataXml = $packageMetaDataEntries -join "`r`n"

$dtprojXml = @"
<?xml version="1.0" encoding="utf-8"?>
<Project xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <DeploymentModel>Project</DeploymentModel>
  <ProductVersion>16.0.5556.0</ProductVersion>
  <SchemaVersion>9.0.1.0</SchemaVersion>
  <State>`$base64`$PFNvdXJjZUNvbnRyb2xJbmZvPjwvU291cmNlQ29udHJvbEluZm8+</State>
  <Database>
    <Name>$ProjectName.database</Name>
    <FullPath>$ProjectName.database</FullPath>
  </Database>
  <DataSources />
  <DataSourceViews />
  <DeploymentModelSpecificContent>
    <Manifest>
      <SSIS:Project SSIS:ProtectionLevel="DontSaveSensitive" xmlns:SSIS="www.microsoft.com/SqlServer/SSIS">
        <SSIS:Properties>
          <SSIS:Property SSIS:Name="ID">{$projectGuid}</SSIS:Property>
          <SSIS:Property SSIS:Name="Name">$ProjectName</SSIS:Property>
          <SSIS:Property SSIS:Name="VersionMajor">1</SSIS:Property>
          <SSIS:Property SSIS:Name="VersionMinor">0</SSIS:Property>
          <SSIS:Property SSIS:Name="VersionBuild">0</SSIS:Property>
          <SSIS:Property SSIS:Name="VersionComments">Generated by SSIS Copilot Toolkit</SSIS:Property>
          <SSIS:Property SSIS:Name="CreationDate">$((Get-Date).ToString('o'))</SSIS:Property>
          <SSIS:Property SSIS:Name="CreatorName">$([Environment]::UserName)</SSIS:Property>
          <SSIS:Property SSIS:Name="CreatorComputerName">$([Environment]::MachineName)</SSIS:Property>
          <SSIS:Property SSIS:Name="Description">Demo SSIS project for the Copilot Toolkit walkthrough</SSIS:Property>
          <SSIS:Property SSIS:Name="PasswordVerifier" SSIS:Sensitive="1"></SSIS:Property>
          <SSIS:Property SSIS:Name="FormatVersion">1</SSIS:Property>
        </SSIS:Properties>
        <SSIS:Packages>
$($packageItems -join "`r`n")
        </SSIS:Packages>
        <SSIS:ConnectionManagers>
$($connMgrItems -join "`r`n")
        </SSIS:ConnectionManagers>
        <SSIS:DeploymentInfo>
          <SSIS:ProjectConnectionParameters />
          <SSIS:PackageInfo>
$packageMetaDataXml
          </SSIS:PackageInfo>
        </SSIS:DeploymentInfo>
      </SSIS:Project>
    </Manifest>
  </DeploymentModelSpecificContent>
  <ControlFlowParts />
  <Miscellaneous />
  <Configurations>
    <Configuration>
      <Name>Development</Name>
      <Options>
        <OutputPath>bin</OutputPath>
        <ConnectionMappings />
        <ConnectionProviderMappings />
        <ConnectionSecurityMappings />
        <DatabaseStorageLocations />
        <TargetServerVersion>SQLServer2025</TargetServerVersion>
        <ParameterConfigurationValues />
      </Options>
    </Configuration>
  </Configurations>
</Project>
"@

Write-Host "  Creating $dtprojPath" -ForegroundColor Gray
[System.IO.File]::WriteAllText($dtprojPath, $dtprojXml, [System.Text.Encoding]::UTF8)

# ---------------------------------------------------------------------------
# 4. Generate Project.params file
# ---------------------------------------------------------------------------

$paramsPath = Join-Path $projectDir 'Project.params'
$paramsXml = @"
<?xml version="1.0"?>
<SSIS:Parameters xmlns:SSIS="www.microsoft.com/SqlServer/SSIS">
  <SSIS:Parameter SSIS:Name="SourceServer">
    <SSIS:Properties>
      <SSIS:Property SSIS:Name="ID">{$(New-Guid)}</SSIS:Property>
      <SSIS:Property SSIS:Name="CreationName"></SSIS:Property>
      <SSIS:Property SSIS:Name="Description">Source SQL Server instance (AdventureWorks2025)</SSIS:Property>
      <SSIS:Property SSIS:Name="IncludeInDebugDump">0</SSIS:Property>
      <SSIS:Property SSIS:Name="Required">1</SSIS:Property>
      <SSIS:Property SSIS:Name="Sensitive">0</SSIS:Property>
      <SSIS:Property SSIS:Name="Value">$SourceServer</SSIS:Property>
      <SSIS:Property SSIS:Name="DataType">18</SSIS:Property>
    </SSIS:Properties>
  </SSIS:Parameter>
  <SSIS:Parameter SSIS:Name="TargetServer">
    <SSIS:Properties>
      <SSIS:Property SSIS:Name="ID">{$(New-Guid)}</SSIS:Property>
      <SSIS:Property SSIS:Name="CreationName"></SSIS:Property>
      <SSIS:Property SSIS:Name="Description">Target SQL Server instance (CopilotSSIS_Warehouse)</SSIS:Property>
      <SSIS:Property SSIS:Name="IncludeInDebugDump">0</SSIS:Property>
      <SSIS:Property SSIS:Name="Required">1</SSIS:Property>
      <SSIS:Property SSIS:Name="Sensitive">0</SSIS:Property>
      <SSIS:Property SSIS:Name="Value">$TargetServer</SSIS:Property>
      <SSIS:Property SSIS:Name="DataType">18</SSIS:Property>
    </SSIS:Properties>
  </SSIS:Parameter>
</SSIS:Parameters>
"@

Write-Host "  Creating $paramsPath" -ForegroundColor Gray
[System.IO.File]::WriteAllText($paramsPath, $paramsXml, [System.Text.Encoding]::UTF8)

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "✅ SSIS project files generated successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Project file: " -NoNewline -ForegroundColor Gray
Write-Host $dtprojPath -ForegroundColor White
Write-Host "Connection managers:" -ForegroundColor Gray
Write-Host "  - AdventureWorks2025.conmgr" -ForegroundColor White
Write-Host "  - CopilotSSIS_Warehouse.conmgr" -ForegroundColor White
Write-Host "Packages registered: $($packages.Count)" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Open $ProjectName.dtproj in Visual Studio SSIS Designer" -ForegroundColor Gray
Write-Host "  2. Right-click the project → Properties → Deployment → TargetServerVersion = SQL Server 2025" -ForegroundColor Gray
Write-Host "  3. Update connection manager server names if needed (Edit Connection)" -ForegroundColor Gray
Write-Host "  4. Run packages via right-click → Execute Package" -ForegroundColor Gray
Write-Host ""
