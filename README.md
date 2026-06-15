# sqlcron

A lightweight, database-native job scheduler for SQL Server.

Install a schema and a worker. Schedule SQL jobs using cron syntax.

## Quick Start

### 1. Install the schema

Run the SQL scripts against your database:

```sql
-- Run in order
:r sql/001_install.sql
:r sql/002_procedures.sql
```

Or verify installation:

```sql
EXEC sqlcron.install;
```

### 2. Schedule a job

```sql
EXEC sqlcron.schedule
    @name    = 'cleanup_logs',
    @cron    = '0 2 * * *',
    @command = 'EXEC dbo.CleanupLogs';
```

Human-friendly syntax also works:

```sql
EXEC sqlcron.schedule
    @name    = 'refresh_cache',
    @every   = '15 minutes',
    @command = 'EXEC dbo.RefreshCache';
```

### 3. Start the worker

```bash
pip install -r requirements.txt

python worker/sqlcron_worker.py \
    --connection-string "DRIVER={ODBC Driver 18 for SQL Server};SERVER=localhost;DATABASE=mydb;Trusted_Connection=yes;TrustServerCertificate=yes"
```

Or with environment variables:

```bash
export SQLCRON_CONNECTION_STRING="DRIVER={ODBC Driver 18 for SQL Server};SERVER=localhost;DATABASE=mydb;Trusted_Connection=yes;TrustServerCertificate=yes"
export SQLCRON_POLL_INTERVAL=30
python worker/sqlcron_worker.py
```

Or with Docker:

```bash
docker build -t sqlcron-worker .
docker run -e SQLCRON_CONNECTION_STRING="..." sqlcron-worker
```

## Features

| Feature | Description |
|---------|-------------|
| **Cron scheduling** | Standard 5-field cron expressions |
| **Human-friendly intervals** | `@every = '15 minutes'` auto-converts to cron |
| **Retry policies** | `@retries = 3, @retry_delay_sec = 60` |
| **Job dependencies** | `@depends_on = 'load_customers'` |
| **Distributed locks** | Only one worker runs a job, even with multiple instances |
| **Run history** | Full audit trail in `sqlcron.job_runs` |
| **Failure alerts** | `@notify = 'dba@example.com'` (webhook/email — extensible) |
| **Pause/Resume** | `EXEC sqlcron.pause @name='job'` / `sqlcron.resume` |
| **Manual trigger** | `EXEC sqlcron.run_job @name='job'` |
| **Pure T-SQL mode** | `EXEC sqlcron.tick` called by external scheduler |

## API Reference

### Procedures

```sql
-- Schedule or update a job
EXEC sqlcron.schedule
    @name           = 'my_job',
    @cron           = '*/5 * * * *',    -- OR @every = '5 minutes'
    @command        = 'EXEC dbo.MyProc',
    @retries        = 3,
    @retry_delay_sec = 60,
    @notify         = 'dba@example.com',
    @depends_on     = 'prerequisite_job';

-- Remove a job (deletes history too)
EXEC sqlcron.unschedule @name = 'my_job';

-- Pause / resume
EXEC sqlcron.pause  @name = 'my_job';
EXEC sqlcron.resume @name = 'my_job';

-- Run immediately
EXEC sqlcron.run_job @name = 'my_job';

-- Pure T-SQL polling (call from external scheduler every minute)
EXEC sqlcron.tick;
```

### Tables

```sql
-- View all jobs
SELECT * FROM sqlcron.jobs;

-- View run history
SELECT * FROM sqlcron.job_runs ORDER BY started_at DESC;
```

## Architecture

```
┌──────────────────┐
│   SQL Server     │
│                  │
│  sqlcron.jobs    │◄──── EXEC sqlcron.schedule ...
│  sqlcron.job_runs│
│  sqlcron.locks   │
└────────▲─────────┘
         │
         │  poll every 30s
         │
┌────────┴─────────┐
│ sqlcron-worker    │
│ (Python process)  │
│                   │
│ - croniter parse  │
│ - distributed lock│
│ - retry logic     │
└───────────────────┘
```

### Two modes of operation

| Mode | How it works | Best for |
|------|-------------|----------|
| **Worker mode** (recommended) | Python process polls `sqlcron.jobs` | Production, Docker, containers |
| **Pure T-SQL mode** | External cron/Task Scheduler calls `EXEC sqlcron.tick` every minute | Simple setups, no Python needed |

## Worker CLI Options

| Flag | Env Var | Default | Description |
|------|---------|---------|-------------|
| `--connection-string` | `SQLCRON_CONNECTION_STRING` | localhost trusted | ODBC connection string |
| `--poll-interval` | `SQLCRON_POLL_INTERVAL` | 30 | Seconds between polls |
| `--lock-timeout` | `SQLCRON_LOCK_TIMEOUT` | 300 | Lock expiry in seconds |
| `--log-level` | `SQLCRON_LOG_LEVEL` | INFO | DEBUG/INFO/WARNING/ERROR |

## Cron Expression Reference

```
┌───────────── minute (0-59)
│ ┌───────────── hour (0-23)
│ │ ┌───────────── day of month (1-31)
│ │ │ ┌───────────── month (1-12)
│ │ │ │ ┌───────────── day of week (0-6, Sun=0)
│ │ │ │ │
* * * * *
```

| Expression | Description |
|-----------|-------------|
| `* * * * *` | Every minute |
| `*/5 * * * *` | Every 5 minutes |
| `0 * * * *` | Every hour |
| `0 2 * * *` | Daily at 2:00 AM |
| `0 0 * * 0` | Weekly on Sunday midnight |
| `0 0 1 * *` | Monthly on the 1st |

## License

MIT
