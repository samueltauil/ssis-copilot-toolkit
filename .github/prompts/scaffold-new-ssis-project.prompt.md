---
description: "Scaffold a brand-new SSIS project (.dtproj, Project.params, Source/Warehouse connection managers) via the managed object model. Run once per repo."
agent: ssis-author
argument-hint: "Optional: project name (defaults to CopilotSSISDemo)"
---
> **ROADMAP — not yet runnable.** The current `New-SsisPackage.ps1` only generates `.dtsx` files from metadata JSON; it has no `-ScaffoldProject` mode. The build / round-trip primitives (`Build-SsisIspac.ps1`, `Verify-ClonedProject.ps1`) are also roadmap. Today, use the existing `templates/ssis-project/CopilotSSISDemo.dtproj` as the starting point and add packages to it via the per-pattern generate prompts.

Create the empty SSIS project skeleton that all subsequent generated packages live inside. This prompt is meant to be run **once** at toolkit setup — re-running it will refuse if `templates/ssis-project/*.dtproj` already exists.

Inputs:
- Project name (default `CopilotSSISDemo`).
- Source SQL Server + database (default `sardinha\SQL2025` + `CopilotSSIS_Source` or `AdventureWorks2025`).
- Warehouse SQL Server + database (default `sardinha\SQL2025` + `CopilotSSIS_Warehouse`).

Steps:
1. Confirm `templates/ssis-project/<Name>.dtproj` does **not** already exist. If it does, refuse and tell the user to delete it manually if they really want to start over.
2. Run `.\tools\New-SsisPackage.ps1 -ScaffoldProject -ProjectName <Name> -SourceServer ... -SourceDatabase ... -WarehouseServer ... -WarehouseDatabase ...`. This single dispatch creates:
   - `templates/ssis-project/<Name>.dtproj` (`ProtectionLevel = DontSaveSensitive`)
   - `templates/ssis-project/Project.params` (project parameters: `RunDate`, `BatchId`, `LoadedByPackageRunId`)
   - `templates/ssis-project/ConnectionManagers/Source.conmgr` and `Warehouse.conmgr` (OLE DB, native client)
   - Empty `templates/ssis-project/Packages/` folder.
3. Run `.\tools\Build-SsisIspac.ps1` to confirm the empty project builds to `.ispac` (it will; SSIS allows zero-package projects).
4. Run `.\tools\Verify-ClonedProject.ps1` — clean-clone gate.
5. Report.

Refuse if anything under `templates/ssis-project/` already exists.
