"""
sqlcron-worker — Python-based scheduler worker for sqlcron.

Polls the sqlcron.jobs table, parses cron expressions with croniter,
executes due jobs, records results, and handles retries + distributed locking.
"""

import argparse
import datetime
import logging
import os
import signal
import socket
import sys
import time
import uuid

import pyodbc
from croniter import croniter

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_POLL_INTERVAL = 30  # seconds
DEFAULT_LOCK_TIMEOUT = 300  # seconds — how long a lock is valid
DEFAULT_CONNECTION_STRING = (
    "DRIVER={ODBC Driver 18 for SQL Server};"
    "SERVER=localhost;"
    "DATABASE=master;"
    "Trusted_Connection=yes;"
    "TrustServerCertificate=yes;"
)

WORKER_ID = f"{socket.gethostname()}-{uuid.uuid4().hex[:8]}"

logger = logging.getLogger("sqlcron")


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def get_connection(connection_string: str) -> pyodbc.Connection:
    """Open a new database connection."""
    conn = pyodbc.connect(connection_string, autocommit=True)
    return conn


def ensure_schema(conn: pyodbc.Connection) -> None:
    """Verify sqlcron schema exists (tables should already be created via SQL scripts)."""
    cursor = conn.cursor()
    cursor.execute(
        "SELECT COUNT(*) FROM sys.schemas WHERE name = 'sqlcron'"
    )
    if cursor.fetchone()[0] == 0:
        raise RuntimeError(
            "sqlcron schema not found. Run sql/001_install.sql and sql/002_procedures.sql first."
        )
    cursor.close()


# ---------------------------------------------------------------------------
# Cron helpers
# ---------------------------------------------------------------------------

def compute_next_run(cron_expr: str, base_time: datetime.datetime | None = None) -> datetime.datetime:
    """Return the next UTC run time for a cron expression."""
    base = base_time or datetime.datetime.now(datetime.timezone.utc)
    cron = croniter(cron_expr, base)
    return cron.get_next(datetime.datetime).replace(tzinfo=datetime.timezone.utc)


def is_due(cron_expr: str, last_run: datetime.datetime | None, now: datetime.datetime) -> bool:
    """Check whether a job is due to run."""
    if last_run is None:
        return True
    # Next run after last_run
    next_run = compute_next_run(cron_expr, last_run)
    return next_run <= now


# ---------------------------------------------------------------------------
# Locking (distributed)
# ---------------------------------------------------------------------------

def try_acquire_lock(conn: pyodbc.Connection, job_id: int, timeout_sec: int) -> bool:
    """Try to acquire an exclusive lock for a job. Returns True on success."""
    now = datetime.datetime.now(datetime.timezone.utc)
    expires = now + datetime.timedelta(seconds=timeout_sec)

    cursor = conn.cursor()
    try:
        # Clean expired locks
        cursor.execute(
            "DELETE FROM sqlcron.locks WHERE job_id = ? AND expires_at < ?",
            job_id, now,
        )

        # Try insert
        cursor.execute(
            "INSERT INTO sqlcron.locks (job_id, locked_by, locked_at, expires_at) "
            "VALUES (?, ?, ?, ?)",
            job_id, WORKER_ID, now, expires,
        )
        return True
    except pyodbc.IntegrityError:
        # Another worker holds the lock
        return False
    finally:
        cursor.close()


def release_lock(conn: pyodbc.Connection, job_id: int) -> None:
    """Release the lock for a job."""
    cursor = conn.cursor()
    cursor.execute(
        "DELETE FROM sqlcron.locks WHERE job_id = ? AND locked_by = ?",
        job_id, WORKER_ID,
    )
    cursor.close()


# ---------------------------------------------------------------------------
# Job execution
# ---------------------------------------------------------------------------

def get_due_jobs(conn: pyodbc.Connection) -> list[dict]:
    """Return all active jobs that are due to run."""
    now = datetime.datetime.now(datetime.timezone.utc)
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT j.id, j.name, j.cron, j.command, j.retries, j.retry_delay_sec,
               j.notify, j.depends_on, j.last_run
        FROM sqlcron.jobs j
        WHERE j.is_active = 1
        """
    )
    rows = cursor.fetchall()
    cursor.close()

    due = []
    for row in rows:
        job = {
            "id": row.id,
            "name": row.name,
            "cron": row.cron,
            "command": row.command,
            "retries": row.retries,
            "retry_delay_sec": row.retry_delay_sec,
            "notify": row.notify,
            "depends_on": row.depends_on,
            "last_run": row.last_run,
        }
        if is_due(job["cron"], job["last_run"], now):
            due.append(job)

    return due


def check_dependency(conn: pyodbc.Connection, depends_on: str | None) -> bool:
    """Return True if the dependency job's last run succeeded (or there is no dependency)."""
    if not depends_on:
        return True

    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT TOP 1 jr.status
        FROM sqlcron.job_runs jr
        INNER JOIN sqlcron.jobs j ON j.id = jr.job_id
        WHERE j.name = ?
        ORDER BY jr.id DESC
        """,
        depends_on,
    )
    row = cursor.fetchone()
    cursor.close()

    return row is not None and row.status == "Success"


def execute_job(conn: pyodbc.Connection, job: dict, attempt: int = 1) -> bool:
    """Execute a single job. Returns True on success."""
    start = datetime.datetime.now(datetime.timezone.utc)
    cursor = conn.cursor()

    # Record run start
    cursor.execute(
        """
        INSERT INTO sqlcron.job_runs (job_id, job_name, started_at, status, attempt, worker_id)
        OUTPUT INSERTED.id
        VALUES (?, ?, ?, 'Running', ?, ?)
        """,
        job["id"], job["name"], start, attempt, WORKER_ID,
    )
    run_id = int(cursor.fetchone()[0])

    success = False
    try:
        # Execute the command
        cursor.execute(job["command"])
        # Consume all result sets to avoid "previous SQL not yet done" errors
        while cursor.nextset():
            pass

        end = datetime.datetime.now(datetime.timezone.utc)
        duration_ms = int((end - start).total_seconds() * 1000)

        cursor.execute(
            """
            UPDATE sqlcron.job_runs
            SET finished_at = ?, duration_ms = ?, status = 'Success'
            WHERE id = ?
            """,
            end, duration_ms, run_id,
        )
        cursor.execute(
            """
            UPDATE sqlcron.jobs
            SET last_run = ?, next_run = ?, updated_at = ?
            WHERE id = ?
            """,
            end, compute_next_run(job["cron"], end), end, job["id"],
        )
        logger.info("Job '%s' succeeded (attempt %d, %d ms)", job["name"], attempt, duration_ms)
        success = True

    except Exception as exc:
        end = datetime.datetime.now(datetime.timezone.utc)
        duration_ms = int((end - start).total_seconds() * 1000)
        error_msg = str(exc)[:4000]

        status = "Failed"
        if attempt < job["retries"] + 1:
            status = "Retrying"

        cursor.execute(
            """
            UPDATE sqlcron.job_runs
            SET finished_at = ?, duration_ms = ?, status = ?, error_message = ?
            WHERE id = ?
            """,
            end, duration_ms, status, error_msg, run_id,
        )
        logger.error("Job '%s' failed (attempt %d): %s", job["name"], attempt, error_msg)

    cursor.close()
    return success


def run_with_retries(conn: pyodbc.Connection, job: dict) -> None:
    """Execute a job with retry logic."""
    max_attempts = job["retries"] + 1
    for attempt in range(1, max_attempts + 1):
        ok = execute_job(conn, job, attempt)
        if ok:
            return
        if attempt < max_attempts:
            logger.info(
                "Job '%s': retrying in %d seconds (attempt %d/%d)",
                job["name"], job["retry_delay_sec"], attempt + 1, max_attempts,
            )
            time.sleep(job["retry_delay_sec"])

    # All attempts exhausted — update next_run so it doesn't re-trigger immediately
    now = datetime.datetime.now(datetime.timezone.utc)
    cursor = conn.cursor()
    cursor.execute(
        "UPDATE sqlcron.jobs SET last_run = ?, next_run = ?, updated_at = ? WHERE id = ?",
        now, compute_next_run(job["cron"], now), now, job["id"],
    )
    cursor.close()


# ---------------------------------------------------------------------------
# Main poll loop
# ---------------------------------------------------------------------------

_shutdown = False


def _signal_handler(signum, frame):
    global _shutdown
    logger.info("Received signal %s — shutting down after current cycle.", signum)
    _shutdown = True


def poll_loop(connection_string: str, poll_interval: int, lock_timeout: int) -> None:
    """Main polling loop. Runs until interrupted."""
    global _shutdown

    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    logger.info("sqlcron-worker starting (id=%s, poll=%ds)", WORKER_ID, poll_interval)

    conn = get_connection(connection_string)
    ensure_schema(conn)

    while not _shutdown:
        try:
            jobs = get_due_jobs(conn)
            if jobs:
                logger.info("Found %d due job(s)", len(jobs))

            for job in jobs:
                if _shutdown:
                    break

                # Check dependency
                if not check_dependency(conn, job["depends_on"]):
                    logger.debug(
                        "Skipping '%s' — dependency '%s' not satisfied",
                        job["name"], job["depends_on"],
                    )
                    continue

                # Try distributed lock
                if not try_acquire_lock(conn, job["id"], lock_timeout):
                    logger.debug("Skipping '%s' — locked by another worker", job["name"])
                    continue

                try:
                    run_with_retries(conn, job)
                finally:
                    release_lock(conn, job["id"])

        except pyodbc.Error as exc:
            logger.error("Database error: %s — reconnecting", exc)
            try:
                conn.close()
            except Exception:
                pass
            time.sleep(5)
            conn = get_connection(connection_string)

        if not _shutdown:
            time.sleep(poll_interval)

    logger.info("sqlcron-worker stopped.")
    conn.close()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="sqlcron-worker — polls sqlcron.jobs and executes due jobs",
    )
    parser.add_argument(
        "--connection-string",
        default=os.environ.get("SQLCRON_CONNECTION_STRING", DEFAULT_CONNECTION_STRING),
        help="ODBC connection string (or set SQLCRON_CONNECTION_STRING env var)",
    )
    parser.add_argument(
        "--poll-interval",
        type=int,
        default=int(os.environ.get("SQLCRON_POLL_INTERVAL", DEFAULT_POLL_INTERVAL)),
        help="Seconds between poll cycles (default: 30)",
    )
    parser.add_argument(
        "--lock-timeout",
        type=int,
        default=int(os.environ.get("SQLCRON_LOCK_TIMEOUT", DEFAULT_LOCK_TIMEOUT)),
        help="Seconds before a distributed lock expires (default: 300)",
    )
    parser.add_argument(
        "--log-level",
        default=os.environ.get("SQLCRON_LOG_LEVEL", "INFO"),
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    poll_loop(args.connection_string, args.poll_interval, args.lock_timeout)


if __name__ == "__main__":
    main()
