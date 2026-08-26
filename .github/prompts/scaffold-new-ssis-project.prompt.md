---
description: "Configure the toolkit for this repo (.ssis-toolkit.json) and scaffold the SSIS project skeleton (.dtproj, Project.params, source/target connection managers). Run once per repo."
agent: ssis-author
argument-hint: "Optional: project name, project folder, and the source/target server + database"
---
Set this repository up for agentic SSIS authoring. Run **once**, before any `/generate-*-package` prompt.

There are two artifacts: the toolkit configuration (`.ssis-toolkit.json`) that every other prompt reads, and the Visual Studio project skeleton that generated packages live inside.

Inputs you will gather. Ask for anything the user has not supplied — **do not guess a server or database name**:
- Project name and the repo-relative folder to hold it (e.g. `MyWarehouse` in `src/MyWarehouse`).
- Where metadata JSON, validation SQL, and package docs should live.
- Source connection: display name, server, database.
- Target (warehouse) connection: display name, server, database.
- Warehouse schema names for staging, dimension, and fact. Default `stg` / `dim` / `fact`.

Steps:
1. If `.ssis-toolkit.json` already exists, show the user its current contents and ask whether to update it or leave it alone. Never overwrite it silently.
2. Confirm each server and database is reachable and exists (`mssql_connect`, `mssql_list_databases`). If one does not exist, stop and tell the user — do not invent a substitute.
3. Write `.ssis-toolkit.json` at the repo root:
   ```json
   {
     "projectPath": "src/MyWarehouse",
     "projectName": "MyWarehouse",
     "metadataPath": "etl/metadata",
     "validationSqlPath": "etl/validation",
     "docsPath": "etl/docs",
     "connections": {
       "source": { "name": "CRM", "server": "SQL-PROD-01", "database": "CRM" },
       "target": { "name": "Warehouse", "server": "DW-DEV-01", "database": "AnalyticsWarehouse" }
     },
     "schemas": { "staging": "stg", "dimension": "dim", "fact": "fact" }
   }
   ```
4. If `<projectPath>/<projectName>.dtproj` already exists, stop and tell the user to delete it manually if they really want to start over.
5. Run `.\tools\New-SsisProject.ps1`. With `.ssis-toolkit.json` in place it needs no arguments; every value defaults to the config. It creates:
   - `<projectPath>/<projectName>.dtproj` (`ProtectionLevel = DontSaveSensitive`)
   - `<projectPath>/<sourceConnectionName>.conmgr` and `<targetConnectionName>.conmgr` (OLE DB)
   - `<projectPath>/Project.params` (`SourceServer`, `TargetServer`)
6. Create the `metadataPath`, `validationSqlPath`, and `docsPath` folders if they do not exist.
7. Report the created files and tell the user the next action is a `/generate-*-package` prompt.

Re-run `.\tools\New-SsisProject.ps1` any time packages are added or removed — it rescans the project folder and re-registers every `.dtsx`.
