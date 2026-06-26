---
description: "Generate post-execution SQL validation queries that prove an SSIS package loaded the right number of rows into the right tables with the right shape."
agent: ssis-author
argument-hint: "Package name or metadata JSON path"
---
Given an executed SSIS package, generate the SQL queries a reviewer runs to confirm the load was correct.

Inputs:
- Package name (e.g. `Dim_Customer`) OR the metadata JSON path.

Steps:
1. Read the metadata JSON to determine pattern, source table, target table, business key, and SCD-2 columns (if any).
2. Generate the appropriate validation SQL into `templates/sql/validate-<PackageName>.sql`:
   - **Staging**: row count equals source row count (modulo deliberate filters); `MIN/MAX/SUM` of one numeric column matches source.
   - **Type-1 dim**: row count equals distinct business keys in source; no duplicate `<BusinessKey>` values.
   - **Type-2 dim**: at most one row per business key has `IsCurrent = 1`; `EffectiveTo IS NULL` ⟺ `IsCurrent = 1`; no overlapping date ranges per business key.
   - **Fact**: row count equals staging row count; no NULL surrogate keys (Lookup failures); aggregate of one measure matches an independent source aggregate.
3. Add three "spot-check" queries at the top of the file (e.g. `SELECT TOP 10 …`) and the formal assertions below.
4. Tell the user how to run it: `Invoke-Sqlcmd -ServerInstance "sardinha\SQL2025" -Database "CopilotSSIS_Warehouse" -InputFile templates/sql/validate-<PackageName>.sql`.

Output only SQL files — do not run the queries yourself. The reviewer runs them.
