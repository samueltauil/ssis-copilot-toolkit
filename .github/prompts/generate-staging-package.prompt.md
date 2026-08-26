---
description: "Generate an SSIS staging-load package (source table → staging schema) from metadata JSON via the StagingLoad pattern module."
agent: ssis-author
argument-hint: "Source table (e.g. dbo.Account) and target staging table (e.g. stg.Account)"
---
Generate a **staging-load SSIS package** that copies a source table into the warehouse staging schema.

Read `.ssis-toolkit.json` first — it supplies `metadataPath`, `projectPath`, the source and target connection names, servers, and databases, and `schemas.staging`. If it is missing, stop and tell the user to run `/scaffold-new-ssis-project`.

Inputs you will gather (ask the user only what is missing):
- Source table, plus the server and database it lives on. Confirm it exists with `mssql_list_tables`, then resolve its columns and data types from `INFORMATION_SCHEMA.COLUMNS`. When the source database is AdventureWorks2025, use the `adventureworks-mapping` skill instead of querying. Never invent column names.
- Target staging table. Its schema must equal `schemas.staging` from the config (`stg` by default).
- Truncate before load? Default `true`.

Steps:
1. Write `<metadataPath>/<PackageName>.metadata.json` with `pattern: "staging"`, explicit `source` and `target` blocks (each with `server`, `database`, `schema`, `table`), the columns array, `protectionLevel: "DontSaveSensitive"`, and `truncateBeforeLoad`.
2. Run `.\tools\New-SsisPackage.ps1 -Metadata <path>` — emits `<projectPath>/<PackageName>.dtsx`.
3. Run the delivery gate by invoking the **ssis-validator** agent (skill: [`ssis-delivery-gate`](../skills/ssis-delivery-gate/SKILL.md)) — `Test-SsisPackage.ps1` → `Test-SsisDesignerLoad.ps1`. (`Build-SsisIspac.ps1` and `Verify-ClonedProject.ps1` are roadmap and skipped.)
4. Report per the agent's standard output format.

Refuse if the target schema is not `schemas.staging`. Refuse if the source table cannot be confirmed against the live database or the `adventureworks-mapping` skill.
