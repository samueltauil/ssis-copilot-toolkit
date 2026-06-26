---
description: "Generate a Type-2 (SCD-2) dimension SSIS package (stg.* → dim.* with IsCurrent flag, EffectiveFrom, EffectiveTo) via the Type2Dimension pattern module."
agent: ssis-author
argument-hint: "Staging table and target dimension table with SCD-2 (e.g. stg.Customer → dim.Customer)"
---
Generate a **Slowly Changing Dimension Type 2 SSIS package**: changes to payload columns insert a new row, mark the prior row's `IsCurrent = 0` and set `EffectiveTo`; the new row's `EffectiveFrom = current run time` and `IsCurrent = 1`.

Inputs you will gather:
- Staging table.
- Target dimension table in `dim.*` — must already have the SCD-2 columns (`IsCurrent bit`, `EffectiveFrom datetime2`, `EffectiveTo datetime2`). If missing, write a DDL fragment for the user to run before generating.
- Business key column.
- Surrogate key column.
- Payload columns — changes to *any* of these trigger a new SCD-2 row.
- Optional: custom names for the SCD columns (defaults: `IsCurrent`, `EffectiveFrom`, `EffectiveTo`).

Steps:
1. Verify target dim shape via `mssql_run_query` against `INFORMATION_SCHEMA.COLUMNS`.
2. Write `templates/metadata/<PackageName>.metadata.json` with `pattern: "type2-dim"`, all SCD-2 fields, the columns array, and `protectionLevel: "DontSaveSensitive"`.
3. Run `.\tools\New-SsisPackage.ps1 -Metadata <path>`.
4. Run the delivery gate via `@ssis-validator` (skill: [`ssis-delivery-gate`](../skills/ssis-delivery-gate/SKILL.md)).
5. Report.

Refuse if the target dim is missing any of the three required SCD-2 columns. Provide the user with the exact `ALTER TABLE` statements to add them, then re-prompt.
