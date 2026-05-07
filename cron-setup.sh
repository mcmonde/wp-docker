#!/bin/bash

# =====================================================
# Auto-add database backup cron job (3:00 AM daily)
# =====================================================

# Get current project directory dynamically
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Backup script path
BACKUP_SCRIPT="$PROJECT_DIR/backup.sh"

# Log file path
LOG_FILE="$PROJECT_DIR/backups/cron_log-\$(date +\%F).txt"

# Ensure logs directory exists
mkdir -p "$PROJECT_DIR/backups"

# Cron schedule (3:00 AM daily)
CRON_SCHEDULE="0 3 * * *"

# Cron job
CRON_JOB="$CRON_SCHEDULE $BACKUP_SCRIPT >> $LOG_FILE 2>&1"

echo "Project directory:"
echo "$PROJECT_DIR"

echo ""
echo "Checking existing crontab..."

# Prevent duplicate cron entries
(crontab -l 2>/dev/null | grep -F "$BACKUP_SCRIPT") >/dev/null

if [ $? -eq 0 ]; then
    echo "✅ Cron job already exists."
else
    (
        crontab -l 2>/dev/null
        echo "$CRON_JOB"
    ) | crontab -

    echo "✅ Cron job added successfully."
fi

echo ""
echo "Current crontab:"
crontab -l