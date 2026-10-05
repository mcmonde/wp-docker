#!/bin/bash
# Replace a site URL in that site's database, then flush its rewrites and cache.
# Usage: ./wpd site:url SITE_ID https://old.example https://new.example

set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$#" -ne 3 ]; then
  echo "Usage: ./wpd site:url SITE_ID OLD_URL NEW_URL" >&2
  exit 1
fi

site_id=$1
OLD_URL=$2
NEW_URL=$3

if [ ! -f ".env" ] || [ ! -f "sites/${site_id}.env" ]; then
  echo "Missing .env or sites/${site_id}.env. Run ./wpd env:generate first." >&2
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
  docker compose exec -T -u "${PUID}:${PGID}" "$site_id" wp "${wp_extra[@]}" "$@"
}

wp_exec search-replace "$OLD_URL" "$NEW_URL" --all-tables --skip-columns=guid

if wp_exec plugin is-installed elementor >/dev/null 2>&1; then
  echo "Elementor detected. Replacing Elementor URLs..."
  wp_exec elementor replace-urls "$OLD_URL" "$NEW_URL"
  wp_exec elementor flush-css
fi

wp_exec rewrite flush
wp_exec cache flush

echo "Replaced ${OLD_URL} with ${NEW_URL} on ${site_id}."
