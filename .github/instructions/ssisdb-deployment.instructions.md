---
description: "Use when writing or editing PowerShell helpers under tools/, especially deploy and execute scripts that call SSISDB catalog stored procedures. Covers SSISDB call conventions, parameter binding, and execution status checking."
applyTo: "tools/**/*.ps1, tools/**/*.psm1, install/**/*.ps1"
---
# SSISDB deployment & execution conventions

## Deploy: `catalog.deploy_project`

- Read the `.ispac` as `varbinary(max)` via `OPENROWSET(BULK …, SINGLE_BLOB)` and pass it as `@project_stream`.
- Use a named SSISDB folder per environment (`Demo`, `Dev`, `Prod`) — create the folder via `catalog.create_folder` if it doesn't exist.
- Project name in SSISDB = `.dtproj` base name. Don't rename per deploy.

## Validate: `catalog.validate_package`

Always run after deploy, before first execution. Captures issues `dtexec /Validate` cannot — environment-reference resolution, project parameter binding, missing connection managers in the SSISDB-side catalog.

## Execute: three-step sequence

1. `catalog.create_execution` → returns `@execution_id`.
2. Optional `catalog.set_execution_parameter_value` per parameter override (one call per parameter; `object_type` 20 = project, 30 = package, 50 = server option).
3. `catalog.start_execution`.

Then poll `catalog.executions` for `status` (1 created / 2 running / 3 cancelled / 4 failed / 7 succeeded / 9 stopping).

## Parameter binding rules

- Sensitive parameters: never inline in PowerShell; read from `$env:` (set by `inputs:` in `.vscode/mcp.json`) or via a `Read-Host -AsSecureString` prompt.
- Project parameters override package parameters. Use project parameters for cross-package shared values (connection strings, environment indicators).
- Connection-manager properties bind via `parameter_name` = `CM.<ConnMgrName>.<PropertyName>` (e.g., `CM.Source.InitialCatalog`).

## PowerShell style

- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` at the top of every script.
- Use `Invoke-Sqlcmd` or `System.Data.SqlClient` directly; do not shell out to `sqlcmd.exe` from inside the toolkit.
- Return objects, not strings — scripts that report results should write PSCustomObjects suitable for `Format-Table` or `Export-Csv`.
- Every script accepts `-Server` / `-Database` / `-Folder` / `-Project` parameters with sensible defaults pointing at `sardinha\SQL2025` and `SSISDB`.

## What NOT to do

- Don't use `dtexec /ISServer` from the deploy/execute helpers (it's fine for ad-hoc runs but the helpers go through the catalog procs directly so failures surface as SQL errors, not exit codes).
- Don't deploy via `ISDeploymentWizard.exe` from automation. It's a GUI; documented but interactive.
- Don't write to `msdb` storage. Project Deployment Model only.
