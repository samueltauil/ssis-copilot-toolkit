---
description: "Generate a fact-load SSIS package (staging → fact schema with surrogate-key lookups against one or more dimension tables) via the FactLoad pattern module."
agent: ssis-author
argument-hint: "Staging table, target fact table, and the dimension tables to look up against"
---
Generate a **fact-load SSIS package**: rows in the staging schema are joined to one or more dimension tables via `Lookup` transformations to resolve surrogate keys, then inserted into the fact table.

Read `.ssis-toolkit.json` first for `metadataPath`, `projectPath`, the connections, and `schemas.staging` / `schemas.dimension` / `schemas.fact`. If it is missing, stop and tell the user to run `/scaffold-new-ssis-project`.

Inputs you will gather:
- Staging table.
- Target fact table. Its schema must equal `schemas.fact` (`fact` by default).
- For each dimension lookup:
  - `dimTable` (e.g. `dim.Customer`)
  - `factColumn` (e.g. `CustomerSK`)
  - `joinOn` (e.g. `CustomerBK`) — must exist in BOTH the staging row AND the dimension.
- Measure columns — additive numeric columns on the fact.

Steps:
1. Confirm every dimension referenced in `dimensionLookups` exists and is populated (`mssql_run_query SELECT COUNT(*) FROM <dim>`).
2. Confirm `joinOn` columns exist in both the staging table and the dimension, via `INFORMATION_SCHEMA.COLUMNS`.
3. Write `<metadataPath>/<PackageName>.metadata.json` with `pattern: "fact"`, explicit `source` and `target` blocks (`server`, `database`, `schema`, `table`), `dimensionLookups`, `measureColumns`, the columns array, and `protectionLevel: "DontSaveSensitive"`.
4. Run `.\tools\New-SsisPackage.ps1 -Metadata <path>`.
5. Run the delivery gate by invoking the **ssis-validator** agent (skill: [`ssis-delivery-gate`](../skills/ssis-delivery-gate/SKILL.md)).
6. Report.

Refuse if the target schema is not `schemas.fact`. Refuse if any referenced dimension is empty (the lookup would silently null-route every row) — tell the user to populate the dimension first.
