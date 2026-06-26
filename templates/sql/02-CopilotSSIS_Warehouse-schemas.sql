-- 02-CopilotSSIS_Warehouse-schemas.sql
-- Schemas: stg (staging), dim (dimensions), fact (facts), etl (audit / run telemetry).
USE CopilotSSIS_Warehouse;
GO

IF SCHEMA_ID(N'stg')  IS NULL EXEC(N'CREATE SCHEMA stg');
IF SCHEMA_ID(N'dim')  IS NULL EXEC(N'CREATE SCHEMA dim');
IF SCHEMA_ID(N'fact') IS NULL EXEC(N'CREATE SCHEMA fact');
IF SCHEMA_ID(N'etl')  IS NULL EXEC(N'CREATE SCHEMA etl');
GO
