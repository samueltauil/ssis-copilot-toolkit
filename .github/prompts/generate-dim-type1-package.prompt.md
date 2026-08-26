---
description: "Generate a Type-1 dimension SSIS package (staging → dimension, overwrite-on-key-match) from metadata JSON via the Type1Dimension pattern module."
agent: ssis-author
argument-hint: "Staging table and target dimension table (e.g. stg.Customer → dim.Customer)"
---
Generate a **Type-1 dimension SSIS package**: rows in the staging schema are merged into the dimension schema by business key; on match, payload columns are overwritten; on no match, a new row is inserted with a fresh surrogate key.

Read `.ssis-toolkit.json` first for `metadataPath`, `projectPath`, the connections, and `schemas.staging` / `schemas.dimension`. If it is missing, stop and tell the user to run `/scaffold-new-ssis-project`.

Inputs you will gather:
- Staging table (source of this package) — must already exist via a staging-load package.
- Target dimension table. Its schema must equal `schemas.dimension` (`dim` by default).
- Business key column name (source side and target side).
- Surrogate key column name (target side; auto-generated SK).
- Payload columns — the non-key columns that participate in the overwrite.

Steps:
1. Verify the staging table exists (`mssql_list_tables`) and resolve both tables' columns from `INFORMATION_SCHEMA.COLUMNS`.
2. Write `<metadataPath>/<PackageName>.metadata.json` with `pattern: "type1-dim"`, explicit `source` and `target` blocks (`server`, `database`, `schema`, `table`), `businessKey`, `surrogateKey`, `payloadColumns`, the columns array, and `protectionLevel: "DontSaveSensitive"`.
3. Run `.\tools\New-SsisPackage.ps1 -Metadata <path>`.
4. Run the delivery gate by invoking the **ssis-validator** agent (skill: [`ssis-delivery-gate`](../skills/ssis-delivery-gate/SKILL.md)).
5. Report.

Refuse if the target schema is not `schemas.dimension`. Refuse if `businessKey` and `surrogateKey` are the same column.
