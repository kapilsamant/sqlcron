FROM python:3.12-slim

# Install ODBC driver for SQL Server
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl gnupg2 unixodbc-dev && \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" > /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    ACCEPT_EULA=Y apt-get install -y msodbcsql18 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker/ ./worker/

ENV SQLCRON_POLL_INTERVAL=30
ENV SQLCRON_LOG_LEVEL=INFO

ENTRYPOINT ["python", "worker/sqlcron_worker.py"]
