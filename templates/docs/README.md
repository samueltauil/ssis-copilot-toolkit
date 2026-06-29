# SSIS Package Documentation

Per-package documentation for the SSIS Copilot Toolkit demo packages. Each document includes control flow, data flow, column mappings, runbook, and troubleshooting guidance.

## Documented Packages

### Staging Packages

- **[Stg_Customer.md](Stg_Customer.md)** — Load AdventureWorks2025 `Sales.Customer` (+ person details) into `stg.Customer`. Append mode, no truncation.
- **Stg_SalesOrderHeader** _(Not yet documented)_ — Load AdventureWorks2025 `Sales.SalesOrderHeader` into `stg.SalesOrderHeader`. Required before fact.SalesOrder.

### Type-1 Dimension Packages

- **Dim_Customer_Type1** _(Not yet documented)_ — Build `dim.Customer` from `stg.Customer`, overwrite on key match.

### Type-2 Dimension Packages (SCD-2)

- **Dim_CustomerHistory_Type2** _(Not yet documented)_ — Build `dim.CustomerHistory` from `stg.Customer` with history tracking.

### Fact Packages

- **Fact_SalesOrder** _(Not yet documented)_ — Build `fact.SalesOrder` from `stg.SalesOrderHeader` with dimension lookups.

## How to Generate Documentation

For any package in [../ssis-project/Packages/](../ssis-project/Packages/), select **ssis-author** from the agent picker, then:

```
/generate-package-docs <PackageName>
```

Example:
```
/generate-package-docs Dim_Customer_Type1
```

The agent will:
1. Read the metadata JSON.
2. Infer control flow and data flow from the pattern.
3. Generate `templates/docs/<PackageName>.md`.
4. Update this index.

