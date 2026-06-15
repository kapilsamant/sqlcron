/*
    sqlcron — SQL Server job scheduler
    002_procedures.sql — Core stored procedures.
*/

-- ============================================================
-- sqlcron.schedule — create or update a scheduled job
-- ============================================================
IF OBJECT_ID('sqlcron.schedule', 'P') IS NOT NULL
    DROP PROCEDURE sqlcron.schedule;
GO

CREATE PROCEDURE sqlcron.schedule
    @name           NVARCHAR(128),
    @cron           VARCHAR(128)    = NULL,
    @every          VARCHAR(128)    = NULL,      -- human-friendly: '15 minutes', '1 hour'
    @command        NVARCHAR(MAX),
    @retries        INT             = 0,
    @retry_delay_sec INT            = 30,
    @notify         NVARCHAR(256)   = NULL,
    @depends_on     NVARCHAR(128)   = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Validate: must provide either @cron or @every
    IF @cron IS NULL AND @every IS NULL
    BEGIN
        RAISERROR('Either @cron or @every must be provided.', 16, 1);
        RETURN;
    END

    -- If @every is provided, convert to cron expression
    IF @every IS NOT NULL AND @cron IS NULL
    BEGIN
        DECLARE @interval INT;
        DECLARE @unit     NVARCHAR(20);

        -- Parse "@every = '15 minutes'" or "'1 hour'" etc.
        SET @every = LTRIM(RTRIM(LOWER(@every)));

        -- Extract numeric part and unit
        SET @interval = TRY_CAST(LEFT(@every, PATINDEX('%[^0-9]%', @every) - 1) AS INT);
        SET @unit     = LTRIM(SUBSTRING(@every, PATINDEX('%[^0-9]%', @every), LEN(@every)));

        -- Normalize plural
        IF RIGHT(@unit, 1) = 's'
            SET @unit = LEFT(@unit, LEN(@unit) - 1);

        IF @interval IS NULL OR @interval <= 0
        BEGIN
            RAISERROR('Invalid @every format. Use e.g. ''15 minutes'', ''1 hour'', ''6 hours''.', 16, 1);
            RETURN;
        END

        SET @cron = CASE @unit
            WHEN 'minute' THEN
                CASE WHEN @interval = 1 THEN '* * * * *'
                     ELSE '*/' + CAST(@interval AS VARCHAR) + ' * * * *'
                END
            WHEN 'hour'   THEN
                CASE WHEN @interval = 1 THEN '0 * * * *'
                     ELSE '0 */' + CAST(@interval AS VARCHAR) + ' * * *'
                END
            WHEN 'day'    THEN '0 0 */' + CAST(@interval AS VARCHAR) + ' * *'
            ELSE NULL
        END;

        IF @cron IS NULL
        BEGIN
            RAISERROR('Unsupported @every unit. Supported: minute(s), hour(s), day(s).', 16, 1);
            RETURN;
        END
    END

    -- Validate cron has 5 fields
    IF LEN(@cron) - LEN(REPLACE(@cron, ' ', '')) <> 4
    BEGIN
        RAISERROR('Invalid cron expression. Must have 5 fields: minute hour day month weekday.', 16, 1);
        RETURN;
    END

    -- Validate depends_on exists
    IF @depends_on IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sqlcron.jobs WHERE name = @depends_on)
    BEGIN
        RAISERROR('depends_on job ''%s'' does not exist.', 16, 1, @depends_on);
        RETURN;
    END

    -- Upsert
    IF EXISTS (SELECT 1 FROM sqlcron.jobs WHERE name = @name)
    BEGIN
        UPDATE sqlcron.jobs
        SET cron            = @cron,
            command         = @command,
            retries         = @retries,
            retry_delay_sec = @retry_delay_sec,
            notify          = @notify,
            depends_on      = @depends_on,
            updated_at      = SYSUTCDATETIME()
        WHERE name = @name;

        PRINT 'sqlcron: job ''' + @name + ''' updated.';
    END
    ELSE
    BEGIN
        INSERT INTO sqlcron.jobs (name, cron, command, retries, retry_delay_sec, notify, depends_on)
        VALUES (@name, @cron, @command, @retries, @retry_delay_sec, @notify, @depends_on);

        PRINT 'sqlcron: job ''' + @name + ''' created.';
    END
END
GO

-- ============================================================
-- sqlcron.unschedule — remove a job
-- ============================================================
IF OBJECT_ID('sqlcron.unschedule', 'P') IS NOT NULL
    DROP PROCEDURE sqlcron.unschedule;
GO

CREATE PROCEDURE sqlcron.unschedule
    @name NVARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM sqlcron.jobs WHERE name = @name)
    BEGIN
        RAISERROR('Job ''%s'' not found.', 16, 1, @name);
        RETURN;
    END

    -- Remove locks and history first
    DECLARE @job_id INT = (SELECT id FROM sqlcron.jobs WHERE name = @name);

    DELETE FROM sqlcron.locks    WHERE job_id = @job_id;
    DELETE FROM sqlcron.job_runs WHERE job_id = @job_id;
    DELETE FROM sqlcron.jobs     WHERE id     = @job_id;

    PRINT 'sqlcron: job ''' + @name + ''' removed.';
END
GO

-- ============================================================
-- sqlcron.pause — deactivate a job
-- ============================================================
IF OBJECT_ID('sqlcron.pause', 'P') IS NOT NULL
    DROP PROCEDURE sqlcron.pause;
GO

CREATE PROCEDURE sqlcron.pause
    @name NVARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE sqlcron.jobs
    SET is_active = 0, updated_at = SYSUTCDATETIME()
    WHERE name = @name;

    IF @@ROWCOUNT = 0
        RAISERROR('Job ''%s'' not found.', 16, 1, @name);
    ELSE
        PRINT 'sqlcron: job ''' + @name + ''' paused.';
END
GO

-- ============================================================
-- sqlcron.resume — reactivate a job
-- ============================================================
IF OBJECT_ID('sqlcron.resume', 'P') IS NOT NULL
    DROP PROCEDURE sqlcron.resume;
GO

CREATE PROCEDURE sqlcron.resume
    @name NVARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE sqlcron.jobs
    SET is_active = 1, updated_at = SYSUTCDATETIME()
    WHERE name = @name;

    IF @@ROWCOUNT = 0
        RAISERROR('Job ''%s'' not found.', 16, 1, @name);
    ELSE
        PRINT 'sqlcron: job ''' + @name + ''' resumed.';
END
GO

-- ============================================================
-- sqlcron.run_job — execute a job immediately (manual trigger)
-- ============================================================
IF OBJECT_ID('sqlcron.run_job', 'P') IS NOT NULL
    DROP PROCEDURE sqlcron.run_job;
GO

CREATE PROCEDURE sqlcron.run_job
    @name NVARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @job_id     INT;
    DECLARE @command    NVARCHAR(MAX);
    DECLARE @run_id     BIGINT;
    DECLARE @start      DATETIME2 = SYSUTCDATETIME();

    SELECT @job_id = id, @command = command
    FROM sqlcron.jobs
    WHERE name = @name;

    IF @job_id IS NULL
    BEGIN
        RAISERROR('Job ''%s'' not found.', 16, 1, @name);
        RETURN;
    END

    -- Record run start
    INSERT INTO sqlcron.job_runs (job_id, job_name, started_at, status, worker_id)
    VALUES (@job_id, @name, @start, 'Running', HOST_NAME());

    SET @run_id = SCOPE_IDENTITY();

    -- Execute
    BEGIN TRY
        EXEC sp_executesql @command;

        UPDATE sqlcron.job_runs
        SET finished_at  = SYSUTCDATETIME(),
            duration_ms  = DATEDIFF(MILLISECOND, @start, SYSUTCDATETIME()),
            status       = 'Success'
        WHERE id = @run_id;

        UPDATE sqlcron.jobs
        SET last_run = SYSUTCDATETIME(), updated_at = SYSUTCDATETIME()
        WHERE id = @job_id;
    END TRY
    BEGIN CATCH
        UPDATE sqlcron.job_runs
        SET finished_at    = SYSUTCDATETIME(),
            duration_ms    = DATEDIFF(MILLISECOND, @start, SYSUTCDATETIME()),
            status         = 'Failed',
            error_message  = ERROR_MESSAGE()
        WHERE id = @run_id;
    END CATCH
END
GO

-- ============================================================
-- sqlcron.tick — pure T-SQL polling entry point
--   An external scheduler (cron, Task Scheduler) calls this
--   every minute. It finds due jobs and executes them.
-- ============================================================
IF OBJECT_ID('sqlcron.tick', 'P') IS NOT NULL
    DROP PROCEDURE sqlcron.tick;
GO

CREATE PROCEDURE sqlcron.tick
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @now DATETIME2 = SYSUTCDATETIME();

    -- Find due jobs
    DECLARE @job_name NVARCHAR(128);

    DECLARE job_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name
        FROM sqlcron.jobs
        WHERE is_active = 1
          AND (next_run IS NULL OR next_run <= @now)
          AND (depends_on IS NULL
               OR depends_on IN (
                   -- Last run of the dependency succeeded
                   SELECT j2.name
                   FROM sqlcron.jobs j2
                   INNER JOIN sqlcron.job_runs jr ON jr.job_id = j2.id
                   WHERE jr.status = 'Success'
                     AND jr.id = (SELECT MAX(id) FROM sqlcron.job_runs WHERE job_id = j2.id)
               ));

    OPEN job_cursor;
    FETCH NEXT FROM job_cursor INTO @job_name;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC sqlcron.run_job @name = @job_name;
        END TRY
        BEGIN CATCH
            -- Log but continue with next job
            PRINT 'sqlcron.tick: error running ''' + @job_name + ''': ' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM job_cursor INTO @job_name;
    END

    CLOSE job_cursor;
    DEALLOCATE job_cursor;
END
GO

-- ============================================================
-- sqlcron.install — convenience wrapper that prints status
-- ============================================================
IF OBJECT_ID('sqlcron.install', 'P') IS NOT NULL
    DROP PROCEDURE sqlcron.install;
GO

CREATE PROCEDURE sqlcron.install
AS
BEGIN
    SET NOCOUNT ON;
    -- If this procedure exists, everything was already installed
    -- by running the SQL scripts. This is a no-op confirmation.
    PRINT '=== sqlcron installed successfully ===';
    PRINT 'Schema  : sqlcron';
    PRINT 'Tables  : sqlcron.jobs, sqlcron.job_runs, sqlcron.locks';
    PRINT 'Procs   : sqlcron.schedule, sqlcron.unschedule, sqlcron.pause, sqlcron.resume, sqlcron.run_job, sqlcron.tick';
    PRINT '';
    PRINT 'Quick start:';
    PRINT '  EXEC sqlcron.schedule @name=''my_job'', @cron=''*/5 * * * *'', @command=''PRINT ''''hello'''''';';
    PRINT '  SELECT * FROM sqlcron.jobs;';
END
GO

PRINT 'sqlcron: all procedures created.';
GO
