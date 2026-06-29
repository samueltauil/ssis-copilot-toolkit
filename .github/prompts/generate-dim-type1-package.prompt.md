---
description: "Generate a Type-1 dimension SSIS package (stg.* → dim.*, overwrite-on-key-match) from metadata JSON via the Type1Dimension pattern module."
agent: ssis-author
argument-hint: "Staging table and target dimension table (e.g. stg.Customer → dim.Customer)"
---
Generate a **Type-1 dimension SSIS package**: rows in `stg.*` are merged into `dim.*` by business key; on match, payload columns are overwritten; on no match, a new row is inserted with a fresh surrogate key.

Inputs you will gather:
- Staging table (source of this package) — must already exist via a staging-load package.
- Target dimension table in `dim.*`.
- Business key column name (source side and target side).
- Surrogate key column name (target side; auto-generated SK).
- Payload columns — the non-key columns that participate in the overwrite.

Steps:
1. Verify the source `stg.*` table exists (`mssql_list_tables`) and matches the dim's expected shape.
2. Write `templates/metadata/<PackageName>.metadata.json` with `pattern: "type1-dim"`, `businessKey`, `surrogateKey`, `payloadColumns`, the columns array, and `protectionLevel: "DontSaveSensitive"`.
3. Run `.\tools\New-SsisPackage.ps1 -Metadata <path>`.
4. Run the delivery gate by invoking the **ssis-validator** agent (skill: [`ssis-delivery-gate`](../skills/ssis-delivery-gate/SKILL.md)).
5. Report.

Refuse if the target schema is not `dim`. Refuse if `businessKey` and `surrogateKey` are the same column.
