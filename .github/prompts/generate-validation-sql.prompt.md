---
description: "Generate post-execution SQL validation queries that prove an SSIS package loaded the right number of rows into the right tables with the right shape."
agent: ssis-author
argument-hint: "Package name or metadata JSON path"
---
Given an executed SSIS package, generate the SQL queries a reviewer runs to confirm the load was correct.

Inputs:
- Package name (e.g. `Dim_Customer`) OR the metadata JSON path.

Steps:
1. Read `.ssis-toolkit.json` for `metadataPath` and `validationSqlPath`.
2. Read the metadata JSON to determine pattern, source table, target table, business key, SCD-2 columns (if any), and the `source` / `target` server and database.
3. Generate the appropriate validation SQL into `<validationSqlPath>/validate-<PackageName>.sql`:
   - **Staging**: row count equals source row count (modulo deliberate filters); `MIN/MAX/SUM` of one numeric column matches source.
   - **Type-1 dim**: row count equals distinct business keys in source; no duplicate `<BusinessKey>` values.
   - **Type-2 dim**: at most one row per business key has `IsCurrent = 1`; `EffectiveTo IS NULL` ⟺ `IsCurrent = 1`; no overlapping date ranges per business key.
   - **Fact**: row count equals staging row count; no NULL surrogate keys (Lookup failures); aggregate of one measure matches an independent source aggregate.
4. Add three "spot-check" queries at the top of the file (e.g. `SELECT TOP 10 …`) and the formal assertions below.
5. Tell the user how to run it, using the server and database from the metadata's `target` block:
   `Invoke-Sqlcmd -ServerInstance "<target.server>" -Database "<target.database>" -InputFile <validationSqlPath>/validate-<PackageName>.sql`

Output only SQL files — do not run the queries yourself. The reviewer runs them.
