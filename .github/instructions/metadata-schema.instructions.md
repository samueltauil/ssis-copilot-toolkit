---
description: "Use when authoring or editing the metadata JSON inputs that drive the SSIS package generator. Covers the schema, required fields per pattern, and the validation rules the generator enforces."
applyTo: "**/*.metadata.json"
---
# Metadata JSON schema

The agent does not write `.dtsx`. It writes JSON in this shape, which `tools/New-SsisPackage.ps1` turns into a `.dtsx` via the managed-OM host.

Metadata files live under the `metadataPath` configured in `.ssis-toolkit.json`.

## Shared top-level fields (every pattern)

```jsonc
{
  "pattern": "staging" | "type1-dim" | "type2-dim" | "fact",
  "packageName": "Stg_Account",                      // file name without .dtsx
  "description": "Loads dbo.Account -> stg.Account",

  "sourceConnection": "CRM",                         // connection-manager name in the .dtproj
  "targetConnection": "Warehouse",

  // Required. No defaults - the generator fails if server or database is missing.
  "source": {
    "server":   "SQL-PROD-01",
    "database": "CRM",
    "schema":   "dbo",
    "table":    "Account"
  },
  "target": {
    "server":   "DW-DEV-01",
    "database": "AnalyticsWarehouse",
    "schema":   "stg",
    "table":    "Account"
  },

  "sourceQuery": "SELECT ... FROM dbo.Account",      // optional; built from `columns` when omitted
  "targetTable": "stg.Account",
  "columns": [
    { "source": "AccountId",   "target": "AccountId",   "dataType": "int" },
    { "source": "AccountName", "target": "AccountName", "dataType": "nvarchar(200)" }
  ],

  "protectionLevel": "DontSaveSensitive",            // the only supported value

  // Optional. Overrides the warehouse schema names this package is checked against.
  // Defaults: staging=stg, dimension=dim, fact=fact. Match .ssis-toolkit.json.
  "schemas": { "staging": "stg", "dimension": "dim", "fact": "fact" }
}
```

`connections: { source: {...}, target: {...} }` is accepted as an alternative to the `source` / `target` blocks for server and database.

## Pattern-specific fields

### `pattern: "staging"`
- `truncateBeforeLoad`: `bool` (default `true`).
- `auditTable`: `string` (optional). When set, the package appends an Execute SQL Task inserting a run row into that table — it must have `(PackageName, StartedAt, FinishedAt, Status, RowsLoaded)`. Omit it and no audit task is generated.

### `pattern: "type1-dim"`
- `businessKey`: `string` — column name in `columns[].target` that matches the source's natural key.
- `surrogateKey`: `string` — auto-generated SK column on the dimension.
- `payloadColumns`: `string[]` — non-key columns that participate in the Type-1 overwrite. At least one.

### `pattern: "type2-dim"`
- `businessKey`, `surrogateKey`, `payloadColumns`: as above. Changes to a payload column trigger a new row.
- `currentFlagColumn`: `string` (default `"IsCurrent"`).
- `effectiveFromColumn`: `string` (default `"EffectiveFrom"`).
- `effectiveToColumn`: `string` (default `"EffectiveTo"`).

### `pattern: "fact"`
- `dimensionLookups`: `array` of `{ "dimTable": "dim.Customer", "factColumn": "CustomerSK", "joinOn": "CustomerBK" }`. At least one.
- `measureColumns`: `string[]` — additive numeric columns on the fact.

## What the generator enforces before emitting `.dtsx`

1. `pattern` resolves to one of the four builders; anything else exits with code 3.
2. `packageName`, `sourceConnection`, `targetConnection`, and `targetTable` are present.
3. `source` and `target` each supply a non-empty `server` and `database`. There is no fallback — a missing value is a hard error naming the field.
4. `targetTable` sits in the schema for the pattern (`schemas.staging` / `.dimension` / `.fact`).
5. Dimension patterns: `businessKey` differs from `surrogateKey`, and `payloadColumns` is non-empty.
6. Fact pattern: `dimensionLookups` and `measureColumns` are present and non-empty.

The generated package is always authored with `ProtectionLevel = DontSaveSensitive`; keep the metadata field set to that value so the intent is explicit in review.

## Column names

Never invent column names. At authoring time, query the source and target schemas via the MCP tools (`mssql_list_tables`, `mssql_run_query` against `INFORMATION_SCHEMA.COLUMNS`) to discover actual column names and data types. If MCP database access is unavailable, ask the user to confirm column names explicitly.

When the source database is AdventureWorks2025, the `adventureworks-mapping` skill (`.github/skills/adventureworks-mapping/SKILL.md`) pins the canonical mapping — use it instead of querying.

## Type gotchas

- If a source column is `varchar` (`DT_STR`) and the target is `nvarchar` (`DT_WSTR`), `CAST` it in `sourceQuery`. Implicit conversion at the destination fails validation with `0xC02020F6`.
