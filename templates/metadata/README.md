# Metadata JSON files live here

Each file describes one SSIS package and is consumed by `tools/New-SsisPackage.ps1`.  
Schema: see [.github/instructions/metadata-schema.instructions.md](../../.github/instructions/metadata-schema.instructions.md).

## Files in this directory

| File | Pattern | Purpose |
|------|---------|---------|
| `Stg_Customer.metadata.json` | staging | Load `Sales.Customer` from AdventureWorks2025 into `stg.Customer` |
| `Stg_SalesOrderHeader.metadata.json` | staging | Load `Sales.SalesOrderHeader` from AdventureWorks2025 into `stg.SalesOrderHeader` |
| `Dim_Customer_Type1.metadata.json` | type1 | Build `dim.Customer` from `stg.Customer` (overwrite on key match) |
| `Dim_CustomerHistory_Type2.metadata.json` | type2 | Build `dim.CustomerHistory` from `stg.Customer` (SCD Type 2 with history tracking) |
| `Fact_SalesOrder.metadata.json` | fact | Build `fact.SalesOrder` from `stg.SalesOrderHeader` with dimension lookups |

## Execution order

For a complete data warehouse load, execute packages in dependency order:

1. **Stg_Customer** — populates `stg.Customer` from source
2. **Stg_SalesOrderHeader** — populates `stg.SalesOrderHeader` from source (required before fact load)
3. **Dim_Customer_Type1** — populates `dim.Customer` from `stg.Customer`
4. **Dim_CustomerHistory_Type2** — populates `dim.CustomerHistory` from `stg.Customer`
5. **Fact_SalesOrder** — populates `fact.SalesOrder` from `stg.SalesOrderHeader`, requires `dim.Customer` for lookups
