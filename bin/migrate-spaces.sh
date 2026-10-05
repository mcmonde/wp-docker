#!/bin/bash
# Upload existing wp-content/uploads media to DigitalOcean Spaces for one or more sites.
# Usage: ./wpd spaces:migrate [SITE_ID ...] [--dry-run] [--keep-local] [--force] [--limit=N] [--offset=N]
# Example: ./wpd spaces:migrate blog --dry-run
# Example: ./wpd spaces:migrate blog default --limit=100

set -euo pipefail

cd "$(dirname "$0")/.."
shopt -s nullglob

if [ ! -f .env ]; then
  echo ".env not found. Run ./wpd env:generate first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

site_ids=()
wp_args=(migrate)
for arg in "$@"; do
  case "$arg" in
    --*)
      wp_args+=("$arg")
      ;;
    *)
      site_ids+=("$arg")
      ;;
  esac
done

if [ "${#site_ids[@]}" -eq 0 ]; then
  for site_file in sites/*.env; do
    enabled=$(grep -E '^SPACES_ENABLED=' "$site_file" | tail -n 1 | cut -d= -f2- | tr '[:upper:]' '[:lower:]')
    [ "$enabled" = "yes" ] || continue
    site_ids+=("$(basename "$site_file" .env)")
  done
fi

if [ "${#site_ids[@]}" -eq 0 ]; then
  echo "No Spaces-enabled sites found. Set SPACES_ENABLED=yes in sites/<id>.env." >&2
  exit 1
fi

wp_extra=()
if [ "${PUID}" -eq 0 ]; then
  wp_extra+=(--allow-root)
fi

failed=0
for site_id in "${site_ids[@]}"; do
  if [ ! -f "sites/${site_id}.env" ]; then
    echo "Unknown site '${site_id}'." >&2
    failed=1
    continue
  fi

  enabled=$(grep -E '^SPACES_ENABLED=' "sites/${site_id}.env" | tail -n 1 | cut -d= -f2- | tr '[:upper:]' '[:lower:]')
  if [ "$enabled" != "yes" ]; then
    echo "Skipping ${site_id}: SPACES_ENABLED is not yes." >&2
    continue
  fi

  echo "=== ${site_id} ==="
  if ! docker compose exec -T -u "${PUID}:${PGID}" "$site_id" wp "${wp_extra[@]}" do-spaces "${wp_args[@]}"; then
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
