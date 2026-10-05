#!/bin/bash

# =====================================================
# Auto-add database backup cron job (3:00 AM daily)
# =====================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

BACKUP_SCRIPT="$PROJECT_DIR/bin/backup.sh"
OLD_BACKUP_SCRIPT="$PROJECT_DIR/backup.sh"

LOG_FILE="$PROJECT_DIR/backups/cron_log-\$(date +\%F).txt"

mkdir -p "$PROJECT_DIR/backups"

CRON_SCHEDULE="0 3 * * *"
CRON_JOB="$CRON_SCHEDULE $BACKUP_SCRIPT >> $LOG_FILE 2>&1"

echo "Project directory:"
echo "$PROJECT_DIR"

echo ""
echo "Checking existing crontab..."

# Entries from before the scripts moved to bin/ point at a file that no longer exists.
if crontab -l 2>/dev/null | grep -F "$OLD_BACKUP_SCRIPT " >/dev/null; then
    crontab -l 2>/dev/null | grep -vF "$OLD_BACKUP_SCRIPT " | crontab -
    echo "Removed the old backup cron that pointed at $OLD_BACKUP_SCRIPT."
fi
OLD_RENEW_SCRIPT="$PROJECT_DIR/renew-ssl.sh"
if crontab -l 2>/dev/null | grep -F "$OLD_RENEW_SCRIPT " >/dev/null; then
    current=$(crontab -l 2>/dev/null)
    printf '%s\n' "${current//"$OLD_RENEW_SCRIPT "/"$PROJECT_DIR/bin/renew-ssl.sh "}" | crontab -
    echo "Pointed the SSL renewal cron at $PROJECT_DIR/bin/renew-ssl.sh."
fi

if crontab -l 2>/dev/null | grep -F "$BACKUP_SCRIPT" >/dev/null; then
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
