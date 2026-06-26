---
description: "Generate a fact-load SSIS package (stg.* → fact.* with surrogate-key lookups against one or more dim.* tables) via the FactLoad pattern module."
agent: ssis-author
argument-hint: "Staging table, target fact table, and the dim tables to look up against"
---
Generate a **fact-load SSIS package**: rows in `stg.*` are joined to one or more `dim.*` tables via `Lookup` transformations to resolve surrogate keys, then inserted into `fact.*`.

Inputs you will gather:
- Staging table.
- Target fact table in `fact.*`.
- For each dimension lookup:
  - `dimTable` (e.g. `dim.Customer`)
  - `factColumn` (e.g. `CustomerSK`)
  - `joinOn` (e.g. `CustomerBK`) — must exist in BOTH the staging row AND the dim.
- Measure columns — additive numeric columns on the fact.

Steps:
1. Confirm every dim referenced in `dimensionLookups` exists and is populated (`mssql_run_query SELECT COUNT(*) FROM <dim>`).
2. Confirm `joinOn` columns exist in both staging and dim.
3. Write `templates/metadata/<PackageName>.metadata.json` with `pattern: "fact"`, `dimensionLookups`, `measureColumns`, the columns array, and `protectionLevel: "DontSaveSensitive"`.
4. Run `.\tools\New-SsisPackage.ps1 -Metadata <path>`.
5. Run the delivery gate via `@ssis-validator` (skill: [`ssis-delivery-gate`](../skills/ssis-delivery-gate/SKILL.md)).
6. Report.

Refuse if any referenced dim is empty (the lookup would silently null-route every row). Tell the user to populate the dim first.
