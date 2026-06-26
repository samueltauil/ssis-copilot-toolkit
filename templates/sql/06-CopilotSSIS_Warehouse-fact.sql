-- 06-CopilotSSIS_Warehouse-fact.sql
-- Fact tables. Schema must match the column lists in templates/metadata/Fact_*.metadata.json.
USE CopilotSSIS_Warehouse;
GO

-- Staging table for fact source (loaded by a Stg_SalesOrderHeader staging package).
-- Lives here for convenience so the fact-load demo has a source ready.
IF OBJECT_ID(N'stg.SalesOrderHeader', N'U') IS NULL
BEGIN
    CREATE TABLE stg.SalesOrderHeader
    (
        SalesOrderID          int              NOT NULL,
        OrderDate             datetime2(3)     NOT NULL,
        CustomerID            int              NOT NULL,
        SubTotal              decimal(19, 4)   NOT NULL,
        LoadedAt              datetime2(3)     NOT NULL,
        LoadedByPackageRunId  uniqueidentifier NOT NULL
    );
END
GO

-- Demo fact table. Surrogate keys come from the Type-1 dim.Customer Lookup;
-- additional dims (Date, Product, Territory) can be added later by extending the
-- dimensionLookups[] array in templates/metadata/Fact_SalesOrder.metadata.json.
IF OBJECT_ID(N'fact.SalesOrder', N'U') IS NULL
BEGIN
    CREATE TABLE fact.SalesOrder
    (
        SalesOrderID  int            NOT NULL,
        OrderDate     datetime2(3)   NOT NULL,
        CustomerKey   int            NOT NULL,
        SubTotal      decimal(19, 4) NOT NULL,
        LoadedAt      datetime2(3)   NOT NULL,
        CONSTRAINT PK_fact_SalesOrder PRIMARY KEY CLUSTERED (SalesOrderID),
        CONSTRAINT FK_fact_SalesOrder_Customer
            FOREIGN KEY (CustomerKey) REFERENCES dim.Customer (CustomerKey)
    );
END
GO
