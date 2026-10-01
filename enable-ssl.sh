#!/bin/bash
# Issue a Let's Encrypt certificate over HTTP-01, then publish port 443.
# Requires DOMAIN (bare hostname), WP_HOME (https URL), and a real EMAIL in .env.
# Port 80 must already be reachable from the public internet.

set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo ".env not found. Run ./generate-env.sh, set DOMAIN, WP_HOME, and EMAIL, then retry." >&2
  exit 1
fi

./generate-env.sh

set -a
# shellcheck disable=SC1091
source .env
set +a

case "${DOMAIN}" in
  ""|localhost|127.0.0.1|*://*)
    echo "Set DOMAIN in .env to a public hostname with no scheme, for example example.com." >&2
    exit 1
    ;;
esac

case "${WP_HOME}" in
  https://*) ;;
  *)
    echo "Set WP_HOME in .env to the https site URL, for example https://${DOMAIN}." >&2
    exit 1
    ;;
esac

home_host=${WP_HOME#https://}
home_host=${home_host%%/*}
if [ "$home_host" != "$DOMAIN" ]; then
  echo "WP_HOME host (${home_host}) and DOMAIN (${DOMAIN}) differ. They must match." >&2
  exit 1
fi

case "${EMAIL}" in
  ""|*example.com|*here.com)
    echo "Set EMAIL in .env to an address Let's Encrypt can use." >&2
    exit 1
    ;;
esac

echo "Starting the HTTP stack so the ACME challenge can be served..."
docker compose up -d db redis wordpress nginx

echo "Requesting a certificate for ${DOMAIN}..."
docker compose --profile ssl run --rm certbot certonly \
  --webroot -w /var/www/letsencrypt \
  --email "$EMAIL" \
  --agree-tos \
  --no-eff-email \
  --non-interactive \
  --keep-until-expiring \
  -d "$DOMAIN"

echo "Publishing HTTPS..."
docker compose -f docker-compose.yml -f docker-compose.ssl.yml up -d nginx

reloaded=0
for _ in 1 2 3 4 5; do
  if docker compose exec -T nginx nginx -s reload; then
    reloaded=1
    break
  fi
  sleep 2
done
if [ "$reloaded" -ne 1 ]; then
  echo "Nginx did not reload. Check docker compose logs nginx." >&2
  exit 1
fi

renew_script="$(pwd)/renew-ssl.sh"
cron_job="15 4 * * * ${renew_script} >> $(pwd)/backups/ssl-renew.log 2>&1"
mkdir -p backups

if crontab -l 2>/dev/null | grep -F "$renew_script" >/dev/null; then
  echo "Renewal cron already exists."
else
  (
    crontab -l 2>/dev/null || true
    echo "$cron_job"
  ) | crontab -
  echo "Added a daily 04:15 renewal cron."
fi

echo "HTTPS is enabled for https://${DOMAIN}."
