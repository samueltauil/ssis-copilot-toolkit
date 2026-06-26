-- 01-CopilotSSIS_Warehouse-create.sql
-- Creates the demo warehouse database used by every generated SSIS package.
-- Idempotent: skips creation if the database already exists.

IF DB_ID(N'CopilotSSIS_Warehouse') IS NULL
BEGIN
    PRINT 'Creating CopilotSSIS_Warehouse...';
    CREATE DATABASE CopilotSSIS_Warehouse;
END
ELSE
BEGIN
    PRINT 'CopilotSSIS_Warehouse already present.';
END
GO
