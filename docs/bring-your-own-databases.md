# Bring your own databases

The toolkit ships with an AdventureWorks2025 walkthrough, but nothing in the engine depends on it. This page shows how to point the toolkit at your own source system and warehouse.

If you installed the [brownfield overlay](../README.md#brownfield-existing-ssis-repo) into an existing SSIS repo, none of the demo content came with it — you already have a clean slate.

## Prerequisites

Before the first `/generate-*-package` prompt:

| Requirement | Notes |
|---|---|
| **Windows** + **PowerShell 7+** | Windows PowerShell 5.1 also works. |
| **.NET Framework 4.x** | Its `csc.exe` compiles the managed-OM host. No .NET SDK required. |
| **SQL Server 2025 Integration Services (shared components)** | Provides `Microsoft.SqlServer.ManagedDTS.dll` and `dtexec.exe`. The database engine alone is not enough — select Integration Services in the installer. |
| **GitHub Copilot Chat** | Visual Studio 2026 (18.4+) or VS Code. |
| **Network access** to your source and warehouse servers | The agent queries `INFORMATION_SCHEMA.COLUMNS` to resolve column names, and `dtexec /Validate` connects to both sides. |

Compile the host once per machine:

```powershell
.\tools\lib\SsisOmHost\Build-SsisOmHost.ps1
```

You do **not** need AdventureWorks, the `SqlServer` PowerShell module, or `Install-Toolkit.ps1` — those are demo-only.

## 1. Configure the repo

Every prompt and primitive reads `.ssis-toolkit.json` at the repo root. Create it once, either by running `/scaffold-new-ssis-project` (the agent interviews you and writes the file) or by copying [`.ssis-toolkit.example.json`](../.ssis-toolkit.example.json) and editing it:

```json
{
  "projectPath": "src/CustomerWarehouse",
  "projectName": "CustomerWarehouse",
  "metadataPath": "etl/metadata",
  "validationSqlPath": "etl/validation",
  "docsPath": "etl/docs",
  "connections": {
    "source": { "name": "CRM",       "server": "SQL-PROD-01", "database": "CRM" },
    "target": { "name": "Warehouse", "server": "DW-DEV-01",   "database": "AnalyticsWarehouse" }
  },
  "schemas": { "staging": "stg", "dimension": "dim", "fact": "fact" }
}
```

| Key | What it controls |
|---|---|
| `projectPath` | Folder holding the `.dtproj`, `.conmgr`, `Project.params`, and generated `.dtsx` files |
| `projectName` | SSIS project name |
| `metadataPath` | Where metadata JSON lives |
| `validationSqlPath` | Where `/generate-validation-sql` writes T-SQL |
| `docsPath` | Where `/generate-package-docs` writes Markdown |
| `connections.*.name` | Connection-manager name (also the `.conmgr` file name) |
| `connections.*.server` / `.database` | Where each side actually lives. No defaults — the generator fails if either is missing |
| `schemas.*` | Warehouse schema names the four patterns enforce |

Paths are repo-relative and use forward slashes. Commit this file; it is repo configuration, not user state.

## 2. Scaffold the project

```powershell
.\tools\New-SsisProject.ps1
```

With `.ssis-toolkit.json` in place this needs no arguments. It creates the `.dtproj`, one `.conmgr` per connection, and `Project.params`. Every value can still be overridden on the command line:

```powershell
.\tools\New-SsisProject.ps1 `
    -ProjectPath "src/CustomerWarehouse" -ProjectName "CustomerWarehouse" `
    -SourceConnectionName "CRM"       -SourceServer "SQL-PROD-01" -SourceDatabase "CRM" `
    -TargetConnectionName "Warehouse" -TargetServer "DW-DEV-01"   -TargetDatabase "AnalyticsWarehouse"
```

Re-run it whenever you add or remove packages — it rescans the project folder and re-registers every `.dtsx`.

## 3. Create the warehouse schemas

The four patterns are Kimball load shapes, so they expect a staging schema, a dimension schema, and a fact schema. Names come from `schemas` in the config; the defaults are `stg`, `dim`, and `fact`.

```sql
CREATE SCHEMA stg;
CREATE SCHEMA dim;
CREATE SCHEMA fact;
```

Staging packages can optionally write an audit row. That only happens when the metadata sets `auditTable`, so you do not need an `etl` schema unless you want one.

## 4. Author a package from chat

Select **ssis-author** from the agent picker and run a prompt:

```text
/generate-staging-package

Load dbo.Account from the CRM database into stg.Account.
Truncate the staging table before loading.
```

The agent reads `.ssis-toolkit.json`, confirms the table exists with `mssql_list_tables`, resolves columns and data types from `INFORMATION_SCHEMA.COLUMNS`, writes the metadata JSON, generates the `.dtsx`, and runs the delivery gate.

The metadata it produces looks like this — note that `source` and `target` carry explicit server and database:

```json
{
  "pattern": "staging",
  "packageName": "Stg_Account",
  "description": "Load CRM accounts into the warehouse staging area",
  "sourceConnection": "CRM",
  "targetConnection": "Warehouse",
  "source": {
    "server": "SQL-PROD-01",
    "database": "CRM",
    "schema": "dbo",
    "table": "Account"
  },
  "target": {
    "server": "DW-DEV-01",
    "database": "AnalyticsWarehouse",
    "schema": "stg",
    "table": "Account"
  },
  "sourceQuery": "SELECT AccountId, AccountName, ModifiedAt FROM dbo.Account",
  "targetTable": "stg.Account",
  "columns": [
    { "source": "AccountId",   "target": "AccountId",   "dataType": "int" },
    { "source": "AccountName", "target": "AccountName", "dataType": "nvarchar(200)" },
    { "source": "ModifiedAt",  "target": "ModifiedAt",  "dataType": "datetime2" }
  ],
  "truncateBeforeLoad": true,
  "protectionLevel": "DontSaveSensitive"
}
```

You can also drive the generator directly:

```powershell
.\tools\New-SsisPackage.ps1 -Metadata .\etl\metadata\Stg_Account.metadata.json
```

## Using different schema names

If your warehouse uses something other than `stg` / `dim` / `fact`, set them in `.ssis-toolkit.json` and mirror them in each metadata file:

```json
"schemas": { "staging": "staging", "dimension": "dimension", "fact": "facts" }
```

The pattern builders validate `targetTable` against these names, so `staging.Account` is accepted once `schemas.staging` is `staging`.

## What the toolkit will not guess

There is no fallback for a server or database name. Omit `source.server`, `source.database`, `target.server`, or `target.database` and generation fails with a message naming the missing field. This is deliberate: a guessed connection produces a package that validates against a database you never named, and the mistake only surfaces at execution time.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `metadata: 'target.database' is required and has no default` | Add the missing field to the metadata JSON. |
| `targetTable '...' must be in the 'stg' schema` | The target schema does not match `schemas.staging`. Fix the table name or set the schema override. |
| Agent asks you to run `/scaffold-new-ssis-project` | `.ssis-toolkit.json` is missing. |
| `dtexec /Validate` failures | See the [`dtexec-validation-triage`](../.github/skills/dtexec-validation-triage/SKILL.md) skill. |
