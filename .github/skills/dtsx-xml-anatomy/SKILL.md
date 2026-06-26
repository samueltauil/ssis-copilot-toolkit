---
name: dtsx-xml-anatomy
description: "Use when explaining or reasoning about the contents of an SSIS .dtsx file — what each element means, which IDs the managed object model owns, and why hand-editing the XML breaks designer-load and execution. Reference, not a recipe."
---
# DTSX XML anatomy

`.dtsx` is a Microsoft-defined XML format ([MS-DTSX2 spec](https://learn.microsoft.com/openspecs/sql_data_portability/ms-dtsx2/1e88a799-3702-4512-9b1d-efce172b1c61)) that captures everything an SSIS designer needs to recreate the package: control flow, data flow, connections, parameters, configurations, protection level, layout. It is the SSIS designer's serialization format — the designer holds an object model in memory while you edit, and `.dtsx` is what it writes to disk.

## When to load this skill

The agent never hand-edits `.dtsx`. So why have this skill? Three reasons:

1. To explain to a user **why** a request to "just edit the GUID" is being refused.
2. To map a `dtexec` or designer error message ("refId `Package\…` not found") to the structural cause.
3. To reason about a diff in a PR review — what changed in the XML and is the change safe.

## Top-level structure

```xml
<DTS:Executable DTS:refId="Package" DTS:ExecutableType="Microsoft.Package" …>
  <DTS:Property DTS:Name="PackageFormatVersion">8</DTS:Property>
  <DTS:Property DTS:Name="ProtectionLevel">0</DTS:Property>   <!-- 0 = DontSaveSensitive -->
  <DTS:Property DTS:Name="DTSID">{GUID}</DTS:Property>
  <DTS:ConnectionManagers> … </DTS:ConnectionManagers>
  <DTS:Variables> … </DTS:Variables>
  <DTS:Executables> … control flow tasks … </DTS:Executables>
  <DTS:PrecedenceConstraints> … </DTS:PrecedenceConstraints>
  <DTS:DesignTimeProperties> … layout, only used by VS designer … </DTS:DesignTimeProperties>
</DTS:Executable>
```

`PackageFormatVersion` 8 = SQL Server 2017+; SQL Server 2022 / 2025 also write `8`. `ProtectionLevel` 0 = `DontSaveSensitive`.

## IDs the OM owns — DO NOT EDIT

| Attribute | Owner | Effect of manual edit |
|---|---|---|
| `DTS:refId` | OM | Breaks all cross-references inside the package (precedence constraints, parameter bindings, expressions). |
| `DTS:DTSID` (`{GUID}`) | OM | Breaks SSISDB execution history correlation; sometimes designer-load. |
| `lineageId` (on data-flow paths and columns) | Data-flow OM | Breaks data-flow column mapping; runtime errors like "no input column found for output column with lineage id N". |
| `<DTS:Property DTS:Name="ObjectName">` GUID-suffixed values | OM | Designer may rebuild correctly OR may corrupt — never edit. |

## DesignTimeProperties

The `<DTS:DesignTimeProperties>` block stores designer layout (x/y/width/height of each shape in the canvas). It is **VS-designer-only**; runtime ignores it. Diffs here are cosmetic noise. But: don't delete the block — VS will regenerate it but a missing block can prompt an "unsaved layout" dialog.

## Data flow component XML

Data flow tasks contain a `<pipeline>` element with one `<component>` per source/transform/destination. Each `<component>` has `<inputs>` and `<outputs>`, each with `<inputColumns>` and `<outputColumns>` that reference `lineageId`s on prior outputs. **This is the most fragile part of the file.** The OM threads `lineageId`s across the entire data flow; hand-edits typically break it silently (no XML schema violation, but runtime errors).

## Validation tools

| Layer | Tool |
|---|---|
| XML well-formedness | `[xml]$_ = Get-Content <pkg>.dtsx` in PowerShell, or `XmlReader.Read` |
| Schema (XSD) | dtsxschema.xsd ships with SSIS; rarely used standalone — `dtexec /Validate` covers it |
| Runtime validation | `dtexec /File <pkg>.dtsx /Validate /WarnAsError` |
| Designer load | `[Microsoft.SqlServer.Dts.Runtime.Application]::new().LoadPackage(<pkg>.dtsx, $null)` |

The toolkit's `Test-SsisPackage.ps1` runs the runtime-validation step (`dtexec /Validate /WarnAsError`); `Test-SsisDesignerLoad.ps1` covers designer-load.

## References

- MS-DTSX2 spec: https://learn.microsoft.com/openspecs/sql_data_portability/ms-dtsx2/1e88a799-3702-4512-9b1d-efce172b1c61
- Package management overview: https://learn.microsoft.com/sql/integration-services/packages/integration-services-ssis-packages
- `Application.LoadPackage`: https://learn.microsoft.com/dotnet/api/microsoft.sqlserver.dts.runtime.application.loadpackage
