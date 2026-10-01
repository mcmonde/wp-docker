#!/bin/bash

# ==========================================
# AUTOMATED WORDPRESS DATABASE BACKUP
# One dump per site in sites/*.env
# ==========================================

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
BACKUP_DIR="$SCRIPT_DIR/backups"
RETENTION_DAYS=30
ENV_FILE="$SCRIPT_DIR/.env"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env file not found at $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a

shopt -s nullglob
site_files=("$SCRIPT_DIR"/sites/*.env)
if [ "${#site_files[@]}" -eq 0 ]; then
  echo "No sites found in sites/*.env" >&2
  exit 1
fi

/usr/bin/mkdir -p "$BACKUP_DIR"

CONTAINER_NAME="${PROJECT_NAME}_db"
failed=0
for site_file in "${site_files[@]}"; do
  db_name=$(grep -E '^DB_NAME=' "$site_file" | tail -n 1 | cut -d= -f2-)
  site_id=$(basename "$site_file" .env)
  filename="${db_name}_${DATE}.sql.gz"

  echo "Starting backup for ${site_id} (${db_name})..."
  if /usr/bin/docker exec "$CONTAINER_NAME" /usr/bin/mysqldump \
      -u root --password="$MYSQL_ROOT_PASSWORD" "$db_name" 2>/dev/null \
      | /usr/bin/gzip > "$BACKUP_DIR/$filename" && [ -s "$BACKUP_DIR/$filename" ]; then
    echo "Backup saved: $BACKUP_DIR/$filename"
  else
    echo "Backup failed for ${db_name}." >&2
    rm -f "$BACKUP_DIR/$filename"
    failed=1
  fi
done

echo "Cleaning old backups..."
/usr/bin/find "$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
/usr/bin/find "$BACKUP_DIR" -type f -name "cron_log-*.txt" -mtime +"$RETENTION_DAYS" -delete

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "Done."
