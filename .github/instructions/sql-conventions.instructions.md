---
description: "Use when writing or editing SQL Server T-SQL files — DDL, demo data, validation queries, SSISDB stored-procedure callers. Covers naming, schema layout, and SSIS-friendly conventions."
applyTo: "**/*.sql, templates/sql/**"
---
# SQL conventions

## Schemas

| Schema | Purpose |
|---|---|
| `stg` | Staging tables — landing zone for source rows; truncated per load. |
| `dim` | Dimension tables — Type 1 or Type 2. SCD-2 dims include `IsCurrent`, `EffectiveFrom`, `EffectiveTo`. |
| `fact` | Fact tables — surrogate-key-joined to `dim.*`. |
| `etl` | ETL audit / metadata — `etl.PackageRun`, `etl.RowAudit`, parameter overrides. |

## Naming

- **Tables**: `PascalCase`, singular (`dim.Customer`, not `dim.Customers`).
- **Surrogate keys**: `<Table>SK` (`CustomerSK`).
- **Business keys**: `<Table>BK` or the source's natural column name. Pin source columns via the `adventureworks-mapping` skill — do not invent column names.
- **Audit columns** (on every dim/fact): `LoadedAt datetime2(3) NOT NULL`, `LoadedByPackageRunId int NOT NULL`.

## DDL style

- Always include `IF NOT EXISTS` (or `DROP IF EXISTS` for idempotent rebuilds in dev).
- Always specify schema explicitly (`CREATE TABLE dim.Customer`, not `CREATE TABLE Customer`).
- Specify `NOT NULL`/`NULL` on every column.
- Use `datetime2(3)` for timestamps. Avoid `datetime`.
- Use `nvarchar` for all string columns unless the source is strictly ASCII.

## SSIS-friendly patterns

- Wide rows are fine — SSIS data flow handles them. Don't pre-pivot in source SQL.
- For SCD-2: source SELECT returns the natural key + payload columns; SSIS does the lookup-and-conditional-split. Do not implement SCD-2 logic in T-SQL.
- For surrogate-key lookups in fact loads: the dim must already have rows with both `CurrentBK` and `CurrentSK`; SSIS reads it via `Lookup` transformation.

## SSISDB callers

Use the documented procs:
- `SSISDB.catalog.deploy_project`
- `SSISDB.catalog.validate_package`
- `SSISDB.catalog.create_execution` → `set_execution_parameter_value` → `start_execution`

Never use `msdb.dbo.sp_*ssis*` (legacy package deployment — out of scope).
