---
name: ssisdb-deployment
description: "Use when deploying an .ispac to SSISDB and executing packages via catalog stored procedures (catalog.deploy_project, catalog.create_execution, catalog.start_execution). Covers folder/project/environment lifecycle, parameter overrides, and status polling."
---
# SSISDB deployment and execution

## When to load this skill

- Running the `deploy-and-execute` prompt (currently roadmap).
- Writing or reviewing `Publish-SsisIspac.ps1` / `Start-SsisExecution.ps1` (both roadmap primitives).
- Debugging an execution status (failed deploy, package validation, execution timeout).

## Prerequisites

- SQL Server with `SSISDB` catalog provisioned (CLR enabled, catalog created via `SSMS → Integration Services Catalogs → Create Catalog`).
- The SQL login running the deploy is a member of `ssis_admin` (full) or `db_owner` on `SSISDB` for the target folder.
- For execution: the login is a member of `ssis_admin` or has been granted `EXECUTE` on the catalog procs.

## Deploy procedure

```powershell
$Server   = '.\SQL2025'
$Folder   = 'Demo'
$Project  = 'CopilotSSISDemo'
$Ispac    = 'out\CopilotSSISDemo.ispac'

# 1. Create folder if not present
Invoke-Sqlcmd -ServerInstance $Server -Database SSISDB -Query @"
  IF NOT EXISTS (SELECT 1 FROM catalog.folders WHERE name = N'$Folder')
    EXEC catalog.create_folder @folder_name = N'$Folder';
"@

# 2. Deploy via streamed varbinary
$bytes = [System.IO.File]::ReadAllBytes($Ispac)
$conn = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=SSISDB;Integrated Security=true;TrustServerCertificate=true"
$conn.Open()
$cmd = $conn.CreateCommand()
$cmd.CommandText = "DECLARE @op bigint; EXEC catalog.deploy_project @folder_name = @f, @project_name = @p, @project_stream = @s, @operation_id = @op OUTPUT; SELECT @op;"
$null = $cmd.Parameters.Add('@f', [System.Data.SqlDbType]::NVarChar, 128).Value = $Folder
$null = $cmd.Parameters.Add('@p', [System.Data.SqlDbType]::NVarChar, 128).Value = $Project
$null = $cmd.Parameters.Add('@s', [System.Data.SqlDbType]::VarBinary, -1).Value = $bytes
$operationId = $cmd.ExecuteScalar()
```

Then validate via `catalog.validate_project` (whole project) or `catalog.validate_package` (one package):

```sql
DECLARE @valid bigint;
EXEC SSISDB.catalog.validate_package
     @folder_name = N'Demo',
     @project_name = N'CopilotSSISDemo',
     @package_name = N'Dim_Customer.dtsx',
     @validation_id = @valid OUTPUT;
```

Validation results live in `catalog.validations` / `catalog.operation_messages`.

## Execute procedure (three steps)

```sql
DECLARE @exec_id bigint;
EXEC SSISDB.catalog.create_execution
     @folder_name = N'Demo',
     @project_name = N'CopilotSSISDemo',
     @package_name = N'Dim_Customer.dtsx',
     @use32bitruntime = 0,
     @reference_id = NULL,
     @execution_id = @exec_id OUTPUT;

-- optional: per-parameter overrides (one call per parameter)
EXEC SSISDB.catalog.set_execution_parameter_value
     @execution_id = @exec_id,
     @object_type  = 20,                     -- 20 = project, 30 = package, 50 = server option
     @parameter_name = N'RunDate',
     @parameter_value = '2025-01-15';

EXEC SSISDB.catalog.start_execution @execution_id = @exec_id;
```

Then poll:

```sql
SELECT execution_id, status, start_time, end_time
FROM   SSISDB.catalog.executions
WHERE  execution_id = @exec_id;
```

`status` values:

| Value | Meaning |
|---|---|
| 1 | Created |
| 2 | Running |
| 3 | Cancelled |
| 4 | Failed |
| 5 | Pending |
| 7 | Succeeded |
| 8 | Stopping |
| 9 | Completed |

Messages and per-component statistics:

```sql
SELECT * FROM SSISDB.catalog.operation_messages WHERE operation_id = @exec_id;
SELECT * FROM SSISDB.catalog.execution_data_statistics WHERE execution_id = @exec_id;
```

## Connection-manager parameter binding

To override a connection manager property at execution time, the `@parameter_name` follows the convention `CM.<ConnMgrName>.<PropertyName>`:

```sql
EXEC SSISDB.catalog.set_execution_parameter_value
     @execution_id = @exec_id,
     @object_type  = 20,
     @parameter_name = N'CM.Source.InitialCatalog',
     @parameter_value = N'AdventureWorks2025';
```

## Don't

- Don't use `dtexec /ISServer` from the toolkit's helpers — the catalog procs are the supported automation path and surface SQL errors directly.
- Don't `EXEC catalog.deploy_project` from a SQL Agent job with sensitive-data parameters baked in. Use environment references.
- Don't `EXEC catalog.create_execution` with `@use32bitruntime = 1` unless the package legitimately needs a 32-bit OLE DB provider (rare on modern SQL Server).

## References

- `catalog.deploy_project`: https://learn.microsoft.com/sql/integration-services/system-stored-procedures/catalog-deploy-project-ssisdb-database
- `catalog.validate_package`: https://learn.microsoft.com/sql/integration-services/system-stored-procedures/catalog-validate-package-ssisdb-database
- `catalog.create_execution`: https://learn.microsoft.com/sql/integration-services/system-stored-procedures/catalog-create-execution-ssisdb-database
- `catalog.set_execution_parameter_value`: https://learn.microsoft.com/sql/integration-services/system-stored-procedures/catalog-set-execution-parameter-value-ssisdb-database
- `catalog.start_execution`: https://learn.microsoft.com/sql/integration-services/system-stored-procedures/catalog-start-execution-ssisdb-database
- SSISDB views: https://learn.microsoft.com/sql/integration-services/system-views/views-integration-services-catalog
