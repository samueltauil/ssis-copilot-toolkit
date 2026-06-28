# SSIS Package Documentation

Per-package documentation for the SSIS Copilot Toolkit demo packages. Each document includes control flow, data flow, column mappings, runbook, and troubleshooting guidance.

## Documented Packages

### Staging Packages

- **[Stg_Customer.md](Stg_Customer.md)** — Load AdventureWorks2025 `Sales.Customer` (+ person details) into `stg.Customer`. Append mode, no truncation.

### Type-1 Dimension Packages

_(None documented yet)_

### Type-2 Dimension Packages (SCD-2)

_(None documented yet)_

### Fact Packages

_(None documented yet)_

## How to Generate Documentation

For any package in [../ssis-project/Packages/](../ssis-project/Packages/):

```
@ssis-author /generate-package-docs <PackageName>
```

Example:
```
@ssis-author /generate-package-docs Dim_Customer_Type1
```

The agent will:
1. Read the metadata JSON.
2. Infer control flow and data flow from the pattern.
3. Generate `templates/docs/<PackageName>.md`.
4. Update this index.

