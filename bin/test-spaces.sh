#!/bin/bash
# Prove DO Spaces wiring (always) and optionally a live put/delete against Spaces.
# Usage: ./wpd spaces:test [SITE_ID]
# Exit 0 = live upload+delete succeeded (or --wiring-only and wiring is OK)
# Exit 1 = wiring broken, live test failed, or live test could not run (missing setup)

set -euo pipefail

cd "$(dirname "$0")/.."

wiring_only=0
site_id=""
for arg in "$@"; do
  case "$arg" in
    --wiring-only) wiring_only=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: ./wpd spaces:test [SITE_ID] [--wiring-only]

Checks that the DO Spaces Uploads plugin is present and wired into the image
and env generator. Without --wiring-only, also runs a non-destructive live
upload+delete via `wp do-spaces test` for SITE_ID (or the first Spaces-enabled
site).

Setup for the live check:
  1. Put real SPACES_KEY / SPACES_SECRET / SPACES_BUCKET in sites/<id>.env
  2. Set SPACES_ENABLED=yes
  3. ./wpd env:generate && docker compose build && ./wpd up
  4. ./wpd spaces:test <id>
EOF
      exit 0
      ;;
    --*)
      echo "Unknown flag: $arg" >&2
      exit 1
      ;;
    *)
      if [ -n "$site_id" ]; then
        echo "Only one SITE_ID is allowed." >&2
        exit 1
      fi
      site_id=$arg
      ;;
  esac
done

fail=0
pass() { printf 'ok  - %s\n' "$1"; }
bad()  { printf 'FAIL- %s\n' "$1" >&2; fail=1; }

echo "=== DO Spaces wiring ==="

[ -f plugins/do-spaces-uploads/do-spaces-uploads.php ] && pass "plugin bootstrap" || bad "missing plugins/do-spaces-uploads/do-spaces-uploads.php"
[ -f plugins/do-spaces-uploads/includes/class-do-spaces-s3.php ] && pass "S3 client" || bad "missing S3 client"
[ -f plugins/do-spaces-uploads/includes/class-do-spaces-uploads.php ] && pass "uploads service" || bad "missing uploads service"
[ -f plugins/do-spaces-uploads/includes/class-do-spaces-cli.php ] && pass "WP-CLI commands" || bad "missing CLI"
[ -f plugins/do-spaces-uploads/loader.php ] && pass "mu-plugin loader" || bad "missing loader.php"

if grep -q 'COPY plugins/do-spaces-uploads /opt/do-spaces-uploads' Dockerfile; then
  pass "Dockerfile copies plugin to /opt/do-spaces-uploads"
else
  bad "Dockerfile does not COPY plugins/do-spaces-uploads"
fi

if grep -q 'spaces_dst=/var/www/html/wp-content/mu-plugins/do-spaces-uploads.php' docker-entrypoint-wrapper.sh \
  && grep -q 'cp "\$spaces_loader" "\$spaces_dst"' docker-entrypoint-wrapper.sh; then
  pass "entrypoint installs mu-plugin loader"
else
  bad "entrypoint does not install mu-plugins/do-spaces-uploads.php"
fi

required_env=(
  SPACES_ENABLED SPACES_KEY SPACES_SECRET SPACES_BUCKET SPACES_REGION
  SPACES_ENDPOINT SPACES_PUBLIC_URL SPACES_PREFIX SPACES_PATH_STYLE
)
for key in "${required_env[@]}"; do
  if grep -q "^${key}=" sites/example.env.sample; then
    pass "example.env.sample has $key"
  else
    bad "example.env.sample missing $key"
  fi
done

if grep -q 'spaces_config_extra' bin/generate-env.sh \
  && grep -q "define('DO_SPACES_ENABLED'" bin/generate-env.sh \
  && grep -q "define('DO_SPACES_KEY'" bin/generate-env.sh; then
  pass "env:generate injects DO_SPACES_* into WORDPRESS_CONFIG_EXTRA"
else
  bad "env:generate missing DO_SPACES_* injection"
fi

if grep -q "WP_CLI::add_command('do-spaces'" plugins/do-spaces-uploads/includes/class-do-spaces-cli.php; then
  pass "wp do-spaces CLI registered"
else
  bad "wp do-spaces CLI not registered"
fi

echo
echo "=== SigV4 self-check (no network) ==="
if php plugins/do-spaces-uploads/tests/smoke-s3-signing.php; then
  pass "Signature V4 request shape"
else
  bad "Signature V4 self-check failed"
fi

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "Wiring checks failed. Fix the paths above before enabling Spaces." >&2
  exit 1
fi

if [ "$wiring_only" -eq 1 ]; then
  echo
  echo "Wiring OK (--wiring-only). Skipped live Spaces put/delete."
  exit 0
fi

echo
echo "=== Live Spaces put/delete ==="

PLACEHOLDER_KEY=your-key-do-space-here
PLACEHOLDER_SECRET=your-secret-do-space-here
PLACEHOLDER_BUCKET=bucket-name-here

setup_help() {
  cat <<'EOF' >&2

Live test could not run. Enable Spaces and retry:

  1. Edit sites/<id>.env:
       SPACES_ENABLED=yes
       SPACES_KEY=<spaces access key>
       SPACES_SECRET=<spaces secret>
       SPACES_BUCKET=<bucket>
       SPACES_REGION=<region e.g. sgp1>
  2. ./wpd env:generate
  3. docker compose build && ./wpd up
  4. ./wpd spaces:test <id>

Or check wiring only: ./wpd spaces:test --wiring-only
EOF
}

shopt -s nullglob
site_files=(sites/*.env)

if [ ${#site_files[@]} -eq 0 ]; then
  echo "No sites/*.env found (only example.env.sample is present)." >&2
  setup_help
  exit 1
fi

pick_site() {
  local f id enabled key secret bucket
  if [ -n "$site_id" ]; then
    if [ ! -f "sites/${site_id}.env" ]; then
      echo "Unknown site '${site_id}'." >&2
      return 1
    fi
    echo "$site_id"
    return 0
  fi
  for f in "${site_files[@]}"; do
    id=$(basename "$f" .env)
    enabled=$(grep -E '^SPACES_ENABLED=' "$f" | tail -n 1 | cut -d= -f2- | tr '[:upper:]' '[:lower:]')
    [ "$enabled" = "yes" ] || continue
    echo "$id"
    return 0
  done
  return 1
}

if ! site_id=$(pick_site); then
  echo "No Spaces-enabled site. Set SPACES_ENABLED=yes in sites/<id>.env." >&2
  setup_help
  exit 1
fi

site_file="sites/${site_id}.env"
enabled=$(grep -E '^SPACES_ENABLED=' "$site_file" | tail -n 1 | cut -d= -f2- | tr '[:upper:]' '[:lower:]')
key=$(grep -E '^SPACES_KEY=' "$site_file" | tail -n 1 | cut -d= -f2-)
secret=$(grep -E '^SPACES_SECRET=' "$site_file" | tail -n 1 | cut -d= -f2-)
bucket=$(grep -E '^SPACES_BUCKET=' "$site_file" | tail -n 1 | cut -d= -f2-)
region=$(grep -E '^SPACES_REGION=' "$site_file" | tail -n 1 | cut -d= -f2-)

if [ "$enabled" != "yes" ]; then
  echo "Site '${site_id}' has SPACES_ENABLED=${enabled:-unset}." >&2
  setup_help
  exit 1
fi

if [ -z "$key" ] || [ -z "$secret" ] || [ -z "$bucket" ] || [ -z "$region" ] \
  || [ "$key" = "$PLACEHOLDER_KEY" ] || [ "$secret" = "$PLACEHOLDER_SECRET" ] \
  || [ "$bucket" = "$PLACEHOLDER_BUCKET" ]; then
  echo "Site '${site_id}' still has placeholder or empty SPACES_KEY/SECRET/BUCKET/REGION." >&2
  setup_help
  exit 1
fi

# Confirm credentials exist without printing them.
printf 'ok  - site %s has non-placeholder SPACES_* (key len=%s bucket set region=%s)\n' \
  "$site_id" "${#key}" "$region"

if [ ! -f .env ]; then
  echo ".env missing. Run ./wpd env:generate first." >&2
  setup_help
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

if ! docker compose ps --status running --services 2>/dev/null | grep -qx "$site_id"; then
  echo "Container '${site_id}' is not running. Run ./wpd up." >&2
  setup_help
  exit 1
fi

wp_extra=()
if [ "${PUID:-1000}" -eq 0 ]; then
  wp_extra+=(--allow-root)
fi

echo "Running: docker compose exec -T ${site_id} wp do-spaces test"
if docker compose exec -T -u "${PUID}:${PGID}" "$site_id" wp "${wp_extra[@]}" do-spaces test; then
  echo
  echo "Live Spaces put/delete OK for site '${site_id}'."
  exit 0
fi

echo "Live wp do-spaces test failed for '${site_id}'. Check key permissions, bucket, region, and endpoint." >&2
exit 1
