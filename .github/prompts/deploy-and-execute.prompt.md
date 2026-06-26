---
description: "Build the .ispac, deploy it to SSISDB, then execute one or more packages and report status."
agent: ssis-author
argument-hint: "Package name(s) to execute, or 'all' for every package in the project"
---
> **ROADMAP — not yet runnable.** This prompt depends on `tools\Build-SsisIspac.ps1`, `tools\Publish-SsisIspac.ps1`, `tools\Start-SsisExecution.ps1`, and `tools\Verify-ClonedProject.ps1`, none of which ship in the current overlay. The prompt below documents the eventual contract. When invoked today, `@ssis-author` must refuse and tell the user that build/deploy/execute primitives are roadmap items.

End-to-end: build → deploy → execute → report.

Inputs:
- One or more package names, or `all`.
- Optional: SSISDB folder name (default `Demo`).
- Optional: parameter overrides as a hashtable (e.g. `@{ RunDate = '2025-01-15' }`).

Steps:
1. **Build.** `.\tools\Build-SsisIspac.ps1` — produces `out/<ProjectName>.ispac`. Stop if build fails.
2. **Designer-load gate.** `.\tools\Verify-ClonedProject.ps1` — stop on failure.
3. **Deploy.** `.\tools\Publish-SsisIspac.ps1 -Ispac out\<ProjectName>.ispac -Folder <Folder> -Project <ProjectName>`. Uses `catalog.deploy_project`. Stop on failure.
4. **Catalog validate.** `mssql_run_query` `EXEC SSISDB.catalog.validate_package …` for each target package. Stop if any package returns `status != 7`.
5. **Execute.** `.\tools\Start-SsisExecution.ps1 -Folder <Folder> -Project <ProjectName> -Package <Pkg>` per package. Apply parameter overrides via `set_execution_parameter_value`.
6. **Poll.** Query `SSISDB.catalog.executions` until `status` is terminal (7=success, 4=failed, 3=cancelled, 9=stopping). Print elapsed time per execution.
7. **Report.** For each package: execution_id, status name, duration, rows affected (from `catalog.execution_data_statistics`), and a link to the matching `templates/docs/<Pkg>.md` if present.

Refuse if:
- The package has not been generated yet (`templates/ssis-project/Packages/<Pkg>.dtsx` is missing).
- `Verify-ClonedProject.ps1` is failing.
- The user has not provided a value for any sensitive parameter the package requires.
