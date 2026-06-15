/*
    sqlcron — SQL Server job scheduler (pg_cron for SQL Server)
    001_install.sql — Bootstrap script: creates schema, tables, and all procedures.

    Usage:
        EXEC sqlcron.install;
    
    Or run this script directly to set everything up.
*/

-- ============================================================
-- 1. Schema
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'sqlcron')
    EXEC('CREATE SCHEMA sqlcron');
GO

-- ============================================================
-- 2. Tables
-- ============================================================

-- Jobs table — stores every scheduled job definition
IF OBJECT_ID('sqlcron.jobs', 'U') IS NULL
BEGIN
    CREATE TABLE sqlcron.jobs
    (
        id              INT IDENTITY(1,1)   PRIMARY KEY,
        name            NVARCHAR(128)       NOT NULL UNIQUE,
        cron            VARCHAR(128)        NOT NULL,       -- cron expression (5-field)
        command         NVARCHAR(MAX)       NOT NULL,       -- T-SQL to execute
        is_active       BIT                 NOT NULL DEFAULT 1,
        retries         INT                 NOT NULL DEFAULT 0,
        retry_delay_sec INT                 NOT NULL DEFAULT 30,
        notify          NVARCHAR(256)       NULL,           -- email or webhook URL
        depends_on      NVARCHAR(128)       NULL,           -- name of prerequisite job
        next_run        DATETIME2           NULL,
        last_run        DATETIME2           NULL,
        created_at      DATETIME2           NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_at      DATETIME2           NOT NULL DEFAULT SYSUTCDATETIME()
    );
END
GO

-- Job runs table — execution history
IF OBJECT_ID('sqlcron.job_runs', 'U') IS NULL
BEGIN
    CREATE TABLE sqlcron.job_runs
    (
        id              BIGINT IDENTITY(1,1) PRIMARY KEY,
        job_id          INT                 NOT NULL REFERENCES sqlcron.jobs(id),
        job_name        NVARCHAR(128)       NOT NULL,
        started_at      DATETIME2           NOT NULL,
        finished_at     DATETIME2           NULL,
        duration_ms     INT                 NULL,
        status          VARCHAR(20)         NOT NULL DEFAULT 'Running',
            -- Running | Success | Failed | Retrying
        attempt         INT                 NOT NULL DEFAULT 1,
        error_message   NVARCHAR(MAX)       NULL,
        worker_id       NVARCHAR(128)       NULL     -- hostname of the worker that ran it
    );

    CREATE NONCLUSTERED INDEX IX_job_runs_job_id
        ON sqlcron.job_runs (job_id, started_at DESC);

    CREATE NONCLUSTERED INDEX IX_job_runs_status
        ON sqlcron.job_runs (status) INCLUDE (job_id, started_at);
END
GO

-- Distributed lock table — prevents duplicate execution across workers
IF OBJECT_ID('sqlcron.locks', 'U') IS NULL
BEGIN
    CREATE TABLE sqlcron.locks
    (
        job_id          INT                 PRIMARY KEY REFERENCES sqlcron.jobs(id),
        locked_by       NVARCHAR(128)       NOT NULL,
        locked_at       DATETIME2           NOT NULL DEFAULT SYSUTCDATETIME(),
        expires_at      DATETIME2           NOT NULL
    );
END
GO

PRINT 'sqlcron: schema and tables created.';
GO
