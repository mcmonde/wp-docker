#!/bin/bash
# Replace a site URL in the database, then flush rewrites and Redis.
# Usage: ./change-url.sh https://old.example https://new.example

set -euo pipefail

cd "$(dirname "$0")"

if [ "$#" -ne 2 ]; then
  echo "Usage: ./change-url.sh OLD_URL NEW_URL" >&2
  exit 1
fi

OLD_URL=$1
NEW_URL=$2

if [ ! -f .env ]; then
  echo ".env not found. Run ./generate-env.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

wp_extra=()
if [ "${PUID}" -eq 0 ]; then
  wp_extra+=(--allow-root)
fi

wp_exec() {
  docker compose exec -T -u "${PUID}:${PGID}" wordpress wp "${wp_extra[@]}" "$@"
}

wp_exec search-replace "$OLD_URL" "$NEW_URL" --all-tables --skip-columns=guid

if wp_exec plugin is-installed elementor >/dev/null 2>&1; then
  echo "Elementor detected. Replacing Elementor URLs..."
  wp_exec elementor replace-urls "$OLD_URL" "$NEW_URL"
  wp_exec elementor flush-css
fi

wp_exec rewrite flush
docker compose exec -T redis redis-cli FLUSHALL

echo "Replaced ${OLD_URL} with ${NEW_URL}. Rewrites and Redis were flushed."
