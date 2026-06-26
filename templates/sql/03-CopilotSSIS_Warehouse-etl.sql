-- 03-CopilotSSIS_Warehouse-etl.sql
-- etl.PackageRun: every package writes one row per execution (StartedAt, FinishedAt, Status, RowsLoaded).
-- etl.RowAudit:   reserved for fact load row-level audit; columns added in Type-2 / Fact patterns.
USE CopilotSSIS_Warehouse;
GO

IF OBJECT_ID(N'etl.PackageRun', N'U') IS NULL
BEGIN
    CREATE TABLE etl.PackageRun
    (
        PackageRunId   bigint        IDENTITY(1,1) NOT NULL PRIMARY KEY,
        PackageName    nvarchar(200) NOT NULL,
        StartedAt      datetime2(3)  NOT NULL,
        FinishedAt     datetime2(3)  NULL,
        Status         nvarchar(30)  NOT NULL CONSTRAINT DF_etl_PackageRun_Status DEFAULT (N'Running'),
        RowsLoaded     bigint        NULL,
        ErrorMessage   nvarchar(max) NULL,
        InsertedAt     datetime2(3)  NOT NULL CONSTRAINT DF_etl_PackageRun_InsertedAt DEFAULT (SYSUTCDATETIME())
    );
END
GO
