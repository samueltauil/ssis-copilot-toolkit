---
name: dtexec-validation-triage
description: Use to diagnose `dtexec /Validate` exit codes and output when Test-SsisPackage.ps1 reports FAIL. Maps the common DTSER_/DTS_E_ error patterns to root cause (metadata error vs. pattern-module bug vs. environment issue) and the file the agent should edit to fix it (never the .dtsx).
---

# `dtexec /Validate` triage

This skill maps the common `dtexec /Validate` exit codes and error patterns to a one-line diagnosis. Use it when `Test-SsisPackage.ps1` returns FAIL.

## Exit codes (from dtexec docs)

| Exit | Meaning | Likely cause in this toolkit |
|---|---|---|
| 0 | Success | n/a |
| 1 | Failure | Most common — validation error in package. Read the output. |
| 3 | User cancelled | Should not happen in CI; investigate environment. |
| 4 | Unable to locate the requested package | Bad `-Package` path or the `.dtsx` was never written. |
| 5 | Unable to load the requested package | XML corruption — re-run `New-SsisPackage.ps1`; the pattern module is at fault. |
| 6 | Internal syntax error in dtexec command line | Bug in `Test-SsisPackage.ps1`. |

> Source: https://learn.microsoft.com/sql/integration-services/packages/dtexec-utility?view=sql-server-ver17#exit-codes

## Common error patterns and where to fix them

`dtexec /Validate` writes errors as `Error: <code>: <message>`. Match the code, not the message text (messages are localized).

### `DTS_E_OLEDBERROR` / `DTS_E_CANNOTACQUIRECONNECTIONFROMCONNECTIONMANAGER`

The connection manager can't reach SQL Server.

- **Fix in metadata JSON.** Check the `connections` block — server name, database name, integrated security flag. The metadata schema is in [`metadata-schema.instructions.md`](../../instructions/metadata-schema.instructions.md).
- **Not a `.dtsx` fix.** Never edit the `.dtsx` ConnectionManager element directly — regenerate from metadata.

### `DTS_E_OLEDBSRCADAPTERSTATIC_NOCOLUMNS` / `column "X" cannot be found at the datasource`

The SQL query in the OLE DB Source references a column the source table doesn't have.

- **Fix in metadata JSON.** Check the `source.columns` block. Cross-reference against the [`adventureworks-mapping`](../adventureworks-mapping/SKILL.md) skill — never invent column names.
- **If the column is correct but missing on the live DB**, use `mssql_run_query` to confirm against `.\SQL2025`.

### `DTS_E_OLEDBDESTINATIONADAPTERSTATIC_INVALIDDATA` / lineage-ID mismatch

The data flow's column mapping references a `lineageId` that no longer exists. This usually means the package was hand-edited (forbidden), or the pattern module is generating stale IDs.

- **Fix in the pattern module.** Open `tools/lib/patterns/<Pattern>.psm1` and check the data-flow assembly logic.
- **Never patch the `.dtsx` lineageId.** That property is OM-owned. If a fresh regenerate doesn't fix it, run `dtutil /IDRegenerate` as a last resort.

### `DTS_E_CANNOTCONVERTBETWEENUNICODEANDNONUNICODESTRINGCOLUMNS`

Source column is `VARCHAR`, destination is `NVARCHAR` (or vice-versa). The pattern module needs to insert a Data Conversion transform.

- **Fix in the pattern module** (`tools/lib/patterns/*.psm1`). The four patterns are documented in the [`ssis-package-patterns`](../ssis-package-patterns/SKILL.md) skill.

### `Error: Validation timed out`

Network reachability from the agent host to `.\SQL2025`. Not a code fix.

- **Confirm with `mssql_connect`.** If the MCP can reach the server, the SSIS package's connection string is wrong. If it can't, the environment is broken.

### Anything else

Read the message, then ask Microsoft Learn MCP:

```text
microsoft_docs_search query="<error code>"
```

Cite the URL of the result in your diagnosis line.

## What the diagnosis looks like

The `@ssis-validator` verdict expects **one line**, like:

> `diagnosis: DTS_E_OLEDBSRCADAPTERSTATIC_NOCOLUMNS — source.columns[3] ('AccountNum') does not exist on AdventureWorks2025.Sales.Customer; cf. adventureworks-mapping skill.`

Not a paragraph. Not a fix proposal. The author agent does the fix.
