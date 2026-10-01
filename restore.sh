#!/bin/bash

# Restore one site database from backups/<db>_<timestamp>.sql.gz

set -euo pipefail

cd "$(dirname "$0")"

BACKUP_DIR="./backups"
ENV_FILE=".env"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ENV_FILE"
  set +a
else
  echo "Error: .env file not found." >&2
  exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
  echo "Error: backup directory '$BACKUP_DIR' does not exist." >&2
  exit 1
fi

shopt -s nullglob
files=("$BACKUP_DIR"/*.sql.gz)
if [ "${#files[@]}" -gt 0 ]; then
  mapfile -t files < <(printf '%s\n' "${files[@]}" | xargs ls -1t | head -n 10 || true)
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "No backup files found in $BACKUP_DIR" >&2
  exit 1
fi

echo "=========================================="
echo " AVAILABLE BACKUPS (Latest 10)"
echo "=========================================="
i=1
for file in "${files[@]}"; do
  echo "[$i] $(basename "$file")"
  i=$((i + 1))
done
echo "=========================================="

read -r -p "Enter the number of the backup to restore (or 'q' to quit): " choice

if [ "$choice" = "q" ]; then
  echo "Aborting."
  exit 0
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#files[@]} ]; then
  echo "Invalid selection." >&2
  exit 1
fi

SELECTED_FILE="${files[$((choice - 1))]}"
base=$(basename "$SELECTED_FILE" .sql.gz)
db_name=$(printf '%s' "$base" | sed -E 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$//')

if [ -z "$db_name" ] || [ "$db_name" = "$base" ]; then
  echo "Could not read the database name from $(basename "$SELECTED_FILE")." >&2
  exit 1
fi

site_id=""
for site_file in sites/*.env; do
  name=$(grep -E '^DB_NAME=' "$site_file" | tail -n 1 | cut -d= -f2-)
  if [ "$name" = "$db_name" ]; then
    site_id=$(basename "$site_file" .env)
    break
  fi
done

if [ -z "$site_id" ]; then
  echo "No site file matches database '${db_name}'." >&2
  exit 1
fi

echo
echo "WARNING: this will overwrite the database '${db_name}'."
echo "Selected backup: $SELECTED_FILE"
echo
read -r -p "Are you sure you want to proceed? (Type 'yes' to confirm): " confirm

if [ "$confirm" != "yes" ]; then
  echo "Operation cancelled."
  exit 0
fi

echo
echo "Restoring database..."

zcat "$SELECTED_FILE" | docker exec -i "${PROJECT_NAME}_db" mariadb -u root --password="$MYSQL_ROOT_PASSWORD" "$db_name"

echo "Database restore successful."

if [ -n "$site_id" ] && docker ps --format '{{.Names}}' | grep -qx "${PROJECT_NAME}_${site_id}"; then
  echo "Flushing cache for ${site_id}..."
  docker compose exec -T -u "${PUID}:${PGID}" "$site_id" wp cache flush || true
elif [ -n "$site_id" ] && docker ps --format '{{.Names}}' | grep -qx "${PROJECT_NAME}_redis"; then
  docker exec "${PROJECT_NAME}_redis" redis-cli -a "$REDIS_PASSWORD" --no-auth-warning EVAL \
    "local k = redis.call('KEYS', ARGV[1]) for i=1,#k do redis.call('DEL', k[i]) end return #k" \
    0 "${site_id}:*"
  echo "Redis keys for ${site_id} were cleared."
fi
