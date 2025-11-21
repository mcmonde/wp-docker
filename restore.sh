#!/bin/bash

# ==========================================
# AUTOMATED WORDPRESS DATABASE RESTORE
# ==========================================

# 1. Configuration
# ----------------
BACKUP_DIR="./backups"
ENV_FILE=".env"

# 2. Load Environment Variables
# -----------------------------
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' $ENV_FILE | xargs)
else
    echo "❌ Error: .env file not found."
    exit 1
fi

CONTAINER_NAME="${PROJECT_NAME}_db"
DB_USER="${MYSQL_USER}"
DB_PASS="${MYSQL_PASSWORD}"
DB_NAME="${MYSQL_DATABASE}"

# 3. Check Dependencies
# ---------------------
if [ ! -d "$BACKUP_DIR" ]; then
    echo "❌ Error: Backup directory '$BACKUP_DIR' does not exist."
    exit 1
fi

# 4. List Available Backups (Latest First)
# ----------------------------------------
echo "=========================================="
echo " AVAILABLE BACKUPS (Latest 10)"
echo "=========================================="

# Get list of files into an array
files=($(ls -1t "$BACKUP_DIR"/*.sql.gz 2>/dev/null | head -n 10))

if [ ${#files[@]} -eq 0 ]; then
    echo "❌ No backup files found in $BACKUP_DIR"
    exit 1
fi

# Display files with index numbers
i=1
for file in "${files[@]}"; do
    filename=$(basename "$file")
    echo "[$i] $filename"
    ((i++))
done
echo "=========================================="

# 5. User Selection
# -----------------
read -p "Enter the number of the backup to restore (or 'q' to quit): " choice

if [[ "$choice" == "q" ]]; then
    echo "Aborting."
    exit 0
fi

# Validate input is a number and within range
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#files[@]} ]; then
    echo "❌ Invalid selection."
    exit 1
fi

# Get actual filename from array (adjust index for 0-based array)
SELECTED_FILE="${files[$((choice-1))]}"

# 6. Safety Confirmation
# ----------------------
echo ""
echo "⚠️  WARNING: THIS WILL OVERWRITE THE DATABASE '$DB_NAME' ⚠️"
echo "Selected Backup: $SELECTED_FILE"
echo ""
read -p "Are you sure you want to proceed? (Type 'yes' to confirm): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Operation cancelled."
    exit 0
fi

# 7. Perform Restore
# ------------------
echo ""
echo "⏳ Restoring database... please wait."

# Use zcat to uncompress in memory and pipe directly to docker exec
# -i is crucial: it keeps the stdin open for the pipe
zcat "$SELECTED_FILE" | docker exec -i "$CONTAINER_NAME" mariadb -u "$DB_USER" --password="$DB_PASS" "$DB_NAME"

if [ $? -eq 0 ]; then
    echo "✅ Database restore successful."

    # 8. Flush Redis Cache (Recommended)
    # ----------------------------------
    # Since DB changed, old cache is now invalid.
    if docker ps | grep -q "${PROJECT_NAME}_redis"; then
        echo "🧹 Flushing Redis cache..."
        docker exec "${PROJECT_NAME}_redis" redis-cli FLUSHALL
        echo "✅ Cache flushed."
    fi
else
    echo "❌ Restore failed."
    exit 1
fi