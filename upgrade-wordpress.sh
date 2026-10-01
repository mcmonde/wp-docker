#!/bin/bash
# Rebuild the WordPress image and update core on one or more instances.
# Usage: ./upgrade-wordpress.sh [SITE_ID ...]
# With no ids, every site in sites/*.env is updated.
# Example: ./upgrade-wordpress.sh blog

set -euo pipefail

cd "$(dirname "$0")"
shopt -s nullglob

if [ ! -f .env ]; then
  echo ".env not found. Run ./generate-env.sh first." >&2
  exit 1
fi

if [ ! -f docker-compose.sites.yml ]; then
  echo "docker-compose.sites.yml not found. Run ./generate-env.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

normalize_site_id() {
  local id=$1
  id=${id%,}
  id=${id#,}
  printf '%s' "$id"
}

site_ids=()
if [ "$#" -gt 0 ]; then
  for arg in "$@"; do
    site_ids+=("$(normalize_site_id "$arg")")
  done
else
  for site_file in sites/*.env; do
    site_ids+=("$(basename "$site_file" .env)")
  done
fi

if [ "${#site_ids[@]}" -eq 0 ]; then
  echo "No sites found. Add one with ./add-site.sh." >&2
  exit 1
fi

for site_id in "${site_ids[@]}"; do
  if [ -z "$site_id" ]; then
    echo "Empty site id." >&2
    exit 1
  fi
  if [ ! -f "sites/${site_id}.env" ]; then
    echo "Unknown site '${site_id}'. No sites/${site_id}.env." >&2
    exit 1
  fi
done

echo "Sites to upgrade: ${site_ids[*]}"
echo "Run ./backup.sh first if you have not backed up recently."
echo

echo "Rebuilding the WordPress image..."
docker compose build

echo "Restarting the stack..."
docker compose up -d --remove-orphans

wp_extra=()
if [ "${PUID}" -eq 0 ]; then
  wp_extra+=(--allow-root)
fi

failed=0
for site_id in "${site_ids[@]}"; do
  echo
  echo "=== ${site_id} ==="

  if ! docker compose ps --status running -q "$site_id" 2>/dev/null | grep -q .; then
    echo "Container '${site_id}' is not running. Skipping." >&2
    failed=1
    continue
  fi

  if ! docker compose exec -T -u "${PUID}:${PGID}" "$site_id" wp "${wp_extra[@]}" core is-installed >/dev/null 2>&1; then
    echo "WordPress is not installed on '${site_id}' yet. Skipping core update." >&2
    continue
  fi

  docker compose exec -T -u "${PUID}:${PGID}" "$site_id" wp "${wp_extra[@]}" core check-update || true
  docker compose exec -T -u "${PUID}:${PGID}" "$site_id" wp "${wp_extra[@]}" core update
  docker compose exec -T -u "${PUID}:${PGID}" "$site_id" wp "${wp_extra[@]}" core update-db
  docker compose exec -T -u "${PUID}:${PGID}" "$site_id" wp "${wp_extra[@]}" cache flush || true

  echo "Updated ${site_id}."
done

echo
if [ "$failed" -ne 0 ]; then
  echo "Some sites were skipped or failed." >&2
  exit 1
fi

echo "WordPress upgrade finished."
