-- 05-CopilotSSIS_Warehouse-dim.sql
-- Dimension tables. Schema must match the column lists in templates/metadata/Dim_*.metadata.json.
-- LoadedAt is appended by the "DC Insert Audit" / "DC Update Audit" Derived Columns
-- in the Type-1 and Type-2 dimension packages.
SET QUOTED_IDENTIFIER ON;
GO
USE CopilotSSIS_Warehouse;
GO

-- Type-1 (overwrite) dimension.
-- Demo: dim.Customer fed from stg.Customer. CustomerID is the business key;
-- CustomerKey is the IDENTITY surrogate key.
IF OBJECT_ID(N'dim.Customer', N'U') IS NULL
BEGIN
    CREATE TABLE dim.Customer
    (
        CustomerKey    int            IDENTITY(1, 1) NOT NULL,
        CustomerID     int            NOT NULL,
        FirstName      nvarchar(50)   NULL,
        LastName       nvarchar(50)   NULL,
        EmailAddress   nvarchar(50)   NULL,
        LoadedAt       datetime2(3)   NOT NULL,
        CONSTRAINT PK_dim_Customer PRIMARY KEY CLUSTERED (CustomerKey),
        CONSTRAINT UQ_dim_Customer_CustomerID UNIQUE (CustomerID)
    );
END
GO

-- Type-2 (SCD-2) dimension.
-- Each business-key change opens a new row; the prior row is expired by
-- setting IsCurrent = 0 and EffectiveTo = run start time.
IF OBJECT_ID(N'dim.CustomerHistory', N'U') IS NULL
BEGIN
    CREATE TABLE dim.CustomerHistory
    (
        CustomerHistoryKey int            IDENTITY(1, 1) NOT NULL,
        CustomerID         int            NOT NULL,
        FirstName          nvarchar(50)   NULL,
        LastName           nvarchar(50)   NULL,
        EmailAddress       nvarchar(50)   NULL,
        IsCurrent          bit            NOT NULL,
        EffectiveFrom      datetime2(3)   NOT NULL,
        EffectiveTo        datetime2(3)   NULL,
        LoadedAt           datetime2(3)   NOT NULL,
        CONSTRAINT PK_dim_CustomerHistory PRIMARY KEY CLUSTERED (CustomerHistoryKey)
    );
    -- One current row per business key; multiple expired rows allowed.
    CREATE UNIQUE INDEX UX_dim_CustomerHistory_Current
        ON dim.CustomerHistory (CustomerID)
        WHERE IsCurrent = 1;
END
GO
