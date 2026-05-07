#!/bin/bash

# ==========================================
# AUTOMATED WORDPRESS DATABASE BACKUP
# ==========================================

# Absolute path to script directory
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

BACKUP_DIR="$SCRIPT_DIR/backups"
RETENTION_DAYS=30
ENV_FILE="$SCRIPT_DIR/.env"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")

# Load .env
if [ -f "$ENV_FILE" ]; then
    set -o allexport
    source "$ENV_FILE"
    set +o allexport
else
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi

CONTAINER_NAME="${PROJECT_NAME}_db"
FILENAME="${MYSQL_DATABASE}_${DATE}.sql.gz"

/usr/bin/mkdir -p "$BACKUP_DIR"

echo "Starting backup for database: $MYSQL_DATABASE..."

# Dump and gzip
/usr/bin/docker exec "$CONTAINER_NAME" /usr/bin/mysqldump \
    -u "$MYSQL_USER" --password="$MYSQL_PASSWORD" "$MYSQL_DATABASE" 2>/dev/null \
    | /usr/bin/gzip > "$BACKUP_DIR/$FILENAME"

if [ -s "$BACKUP_DIR/$FILENAME" ]; then
    echo "✔ Backup saved: $BACKUP_DIR/$FILENAME"
else
    echo "✖ Backup failed."
    rm -f "$BACKUP_DIR/$FILENAME"
    exit 1
fi

echo "Cleaning old backups..."
/usr/bin/find "$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete
/usr/bin/find "$BACKUP_DIR" -type f -name "cron_log-*.txt" -mtime +$RETENTION_DAYS -delete

echo "Done."
