---
description: "Use when authoring or editing the metadata JSON inputs that drive the SSIS package generator. Covers the schema, required fields per pattern, and the validation rules the generator enforces."
applyTo: "templates/metadata/**, **/*.metadata.json"
---
# Metadata JSON schema

The agent does not write `.dtsx`. It writes JSON in this shape, which the generator turns into a `.dtsx`. The full JSON Schema lives in `templates/metadata/schema.json`.

## Shared top-level fields (every pattern)

```jsonc
{
  "pattern": "staging" | "type1-dim" | "type2-dim" | "fact",
  "packageName": "Stg_Customer",                    // file name without .dtsx
  "description": "Loads Sales.Customer → stg.Customer",
  "sourceConnection": "Source",                     // name of .conmgr in templates/ssis-project/ConnectionManagers/
  "targetConnection": "Warehouse",
  "sourceQuery": "SELECT … FROM Sales.Customer",    // OLE DB Source's SQL command
  "targetTable": "stg.Customer",
  "columns": [
    { "source": "CustomerID",  "target": "CustomerBK", "dataType": "int" },
    { "source": "PersonID",    "target": "PersonID",   "dataType": "int" },
    …
  ],
  "protectionLevel": "DontSaveSensitive"            // required; only this value is accepted
}
```

## Pattern-specific fields

### `pattern: "staging"`
- `truncateBeforeLoad`: `bool` (default `true`).

### `pattern: "type1-dim"`
- `businessKey`: `string` — column name in `columns[].target` that matches source's natural key.
- `surrogateKey`: `string` — auto-generated SK column on the dim.
- `payloadColumns`: `string[]` — non-key columns that participate in the Type-1 overwrite.

### `pattern: "type2-dim"`
- `businessKey`, `surrogateKey`: as above.
- `payloadColumns`: `string[]` — columns whose change triggers a new row.
- `currentFlagColumn`: `string` (default `"IsCurrent"`).
- `effectiveFromColumn`: `string` (default `"EffectiveFrom"`).
- `effectiveToColumn`: `string` (default `"EffectiveTo"`).

### `pattern: "fact"`
- `dimensionLookups`: `array` of `{ "dimTable": "dim.Customer", "factColumn": "CustomerSK", "joinOn": "CustomerBK" }`.
- `measureColumns`: `string[]` — additive numeric columns on the fact.

## What the generator validates before emitting `.dtsx`

1. `pattern` is one of the four allowed values.
2. `packageName` matches `^[A-Z][A-Za-z0-9_]+$`.
3. Both connections exist under `templates/ssis-project/ConnectionManagers/`.
4. Every column in `dimensionLookups[].joinOn` exists in the referenced dim.
5. `protectionLevel` equals `"DontSaveSensitive"`.

Failures stop the pipeline before the OM is even loaded.

## Column names

Never invent AdventureWorks2025 column names. Consult the `adventureworks-mapping` skill (`.github/skills/adventureworks-mapping/SKILL.md`) for the canonical AW → `stg`/`dim` mapping before authoring a metadata JSON.
