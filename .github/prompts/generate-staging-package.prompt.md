---
description: "Generate an SSIS staging-load package (source → stg.*) from metadata JSON via the StagingLoad pattern module."
agent: ssis-author
argument-hint: "Source table (e.g. Sales.Customer) and target staging table (e.g. stg.Customer)"
---
Generate a **staging-load SSIS package** that copies a source table into a `stg.*` table.

Inputs you will gather (ask the user only what is missing):
- Source table — e.g. `Sales.Customer` in AdventureWorks2025. Resolve columns via the `adventureworks-mapping` skill; never invent column names.
- Target staging table — e.g. `stg.Customer`. Schema must be `stg`.
- Truncate before load? Default `true`.

Steps:
1. Write `templates/metadata/<PackageName>.metadata.json` with `pattern: "staging"`, the columns array, `protectionLevel: "DontSaveSensitive"`, and `truncateBeforeLoad`.
2. Run `.\tools\New-SsisPackage.ps1 -Metadata <path>` — emits `templates/ssis-project/Packages/<PackageName>.dtsx`.
3. Run the delivery gate via `@ssis-validator` (skill: [`ssis-delivery-gate`](../skills/ssis-delivery-gate/SKILL.md)) — `Test-SsisPackage.ps1` → `Test-SsisDesignerLoad.ps1`. (`Build-SsisIspac.ps1` and `Verify-ClonedProject.ps1` are roadmap and skipped.)
4. Report per the agent's standard output format.

Refuse if the target schema is not `stg`. Refuse if the source table cannot be confirmed via the `adventureworks-mapping` skill or `mssql_list_tables`.
