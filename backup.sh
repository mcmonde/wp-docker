#!/bin/bash

# ==========================================
# AUTOMATED WORDPRESS DATABASE BACKUP
# ==========================================

# 1. Configuration
# ----------------
BACKUP_DIR="./backups"
RETENTION_DAYS=7
ENV_FILE=".env"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")

# 2. Load Environment Variables
# -----------------------------
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' $ENV_FILE | xargs)
else
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi

# 3. Define Variables based on .env
# ---------------------------------
# Note: We assume container name format based on your docker-compose
CONTAINER_NAME="${PROJECT_NAME}_db"
DB_USER="${MYSQL_USER}"
DB_PASS="${MYSQL_PASSWORD}"
DB_NAME="${MYSQL_DATABASE}"

FILENAME="${DB_NAME}_${DATE}.sql.gz"

# 4. Create Backup Directory if not exists
# ----------------------------------------
mkdir -p "$BACKUP_DIR"

# 5. Perform Backup
# -----------------
echo "Starting backup for database: $DB_NAME..."

# Use docker exec to dump, pipe to gzip, and save to host
docker exec "$CONTAINER_NAME" /usr/bin/mysqldump -u "$DB_USER" --password="$DB_PASS" "$DB_NAME" 2>/dev/null | gzip > "$BACKUP_DIR/$FILENAME"

# Check if backup succeeded (file size > 0)
if [ -s "$BACKUP_DIR/$FILENAME" ]; then
    echo "✅ Backup successful: $BACKUP_DIR/$FILENAME"
else
    echo "❌ Backup failed. File is empty."
    rm -f "$BACKUP_DIR/$FILENAME"
    exit 1
fi

# 6. Rotation (Delete old backups)
# --------------------------------
echo "Cleaning up backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete

echo "Done."