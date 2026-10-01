#!/bin/bash
# Create each site database and limit its user to that database.
# Safe to run more than once. The init script covers a brand-new data volume.
# This covers a MariaDB server that is already initialized.

set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f mysql/init/sites.sql ]; then
  echo "mysql/init/sites.sql is missing. Run ./generate-env.sh first." >&2
  exit 1
fi

if [ ! -f .env ]; then
  echo ".env is missing. Run ./generate-env.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

if ! docker compose ps --status running -q db 2>/dev/null | grep -q .; then
  echo "Database container is not running. ./up.sh creates site databases after MariaDB is up."
  exit 0
fi

docker compose exec -T db mariadb -u root --password="${MYSQL_ROOT_PASSWORD}" < mysql/init/sites.sql
echo "Site databases are present."
