-- 04-CopilotSSIS_Warehouse-stg.sql
-- Staging tables. Schema must match the column lists in templates/metadata/Stg_*.metadata.json.
-- LoadedAt / LoadedByPackageRunId are appended by the "DC Audit" Derived Column in every staging package.
USE CopilotSSIS_Warehouse;
GO

IF OBJECT_ID(N'stg.Customer', N'U') IS NULL
BEGIN
    CREATE TABLE stg.Customer
    (
        CustomerID            int            NOT NULL,
        FirstName             nvarchar(50)   NULL,
        LastName              nvarchar(50)   NULL,
        EmailAddress          nvarchar(50)   NULL,
        StoreID               int            NULL,
        TerritoryID           int            NULL,
        AccountNumber         nvarchar(10)   NULL,
        LoadedAt              datetime2(3)   NOT NULL,
        LoadedByPackageRunId  uniqueidentifier NOT NULL
    );
END
GO
