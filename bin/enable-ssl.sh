#!/bin/bash
# Issue a Let's Encrypt certificate for one or more sites, then publish port 443.
# Usage: ./wpd ssl:enable [SITE_ID ...]
# With no ids, every site that has a public https WP_HOME is included.
# Port 80 must be reachable from the public internet.

set -euo pipefail

cd "$(dirname "$0")/.."
shopt -s nullglob

if [ ! -f .env ]; then
  echo ".env not found. Run ./wpd env:generate, set EMAIL, and retry." >&2
  exit 1
fi

bin/generate-env.sh

set -a
# shellcheck disable=SC1091
source .env
set +a

case "${EMAIL}" in
  ""|*example.com|*here.com)
    echo "Set EMAIL in .env to an address Let's Encrypt can use." >&2
    exit 1
    ;;
esac

explicit=no
if [ "$#" -gt 0 ]; then
  explicit=yes
  site_ids=("$@")
else
  site_ids=()
  for site_file in sites/*.env; do
    site_ids+=("$(basename "$site_file" .env)")
  done
fi

if [ "${#site_ids[@]}" -eq 0 ]; then
  echo "No sites found. Add one with ./wpd site:add." >&2
  exit 1
fi

eligible=()
for site_id in "${site_ids[@]}"; do
  site_file="sites/${site_id}.env"
  if [ ! -f "$site_file" ]; then
    echo "No site file at ${site_file}." >&2
    exit 1
  fi
  domain=$(grep -E '^DOMAIN=' "$site_file" | tail -n 1 | cut -d= -f2-)
  wp_home=$(grep -E '^WP_HOME=' "$site_file" | tail -n 1 | cut -d= -f2-)

  case "$domain" in
    ""|localhost|127.0.0.1|*://*)
      if [ "$explicit" = "yes" ]; then
        echo "Site '${site_id}' needs DOMAIN set to a public hostname." >&2
        exit 1
      fi
      echo "Skipping ${site_id}: DOMAIN is not a public hostname."
      continue
      ;;
  esac

  case "$wp_home" in
    https://*) ;;
    *)
      if [ "$explicit" = "yes" ]; then
        echo "Set WP_HOME in ${site_file} to https://${domain} before enabling TLS." >&2
        exit 1
      fi
      echo "Skipping ${site_id}: WP_HOME is not https."
      continue
      ;;
  esac

  home_host=${wp_home#https://}
  home_host=${home_host%%/*}
  if [ "$home_host" != "$domain" ]; then
    echo "Site '${site_id}' WP_HOME host (${home_host}) and DOMAIN (${domain}) differ." >&2
    exit 1
  fi

  eligible+=("$site_id")
done

if [ "${#eligible[@]}" -eq 0 ]; then
  echo "No sites are ready for HTTPS. Set DOMAIN and an https WP_HOME, then retry." >&2
  exit 1
fi

echo "Starting the stack so the ACME challenge can be served..."
docker compose up -d

for site_id in "${eligible[@]}"; do
  domain=$(grep -E '^DOMAIN=' "sites/${site_id}.env" | tail -n 1 | cut -d= -f2-)
  echo "Requesting a certificate for ${domain}..."
  docker compose --profile ssl run --rm certbot certonly \
    --webroot -w /var/www/letsencrypt \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    -d "$domain"
done

bin/generate-env.sh

echo "Publishing HTTPS..."
docker compose up -d nginx

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

renew_script="$(pwd)/bin/renew-ssl.sh"
cron_job="15 4 * * * ${renew_script} >> $(pwd)/backups/ssl-renew.log 2>&1"
mkdir -p backups

# Entries from before the scripts moved to bin/ point at a file that no longer exists.
old_renew_script="$(pwd)/renew-ssl.sh"
if crontab -l 2>/dev/null | grep -F "${old_renew_script} " >/dev/null; then
  crontab -l 2>/dev/null | { grep -vF "${old_renew_script} " || true; } | crontab -
  echo "Removed the old renewal cron that pointed at ${old_renew_script}."
fi

if crontab -l 2>/dev/null | grep -F "$renew_script" >/dev/null; then
  echo "Renewal cron already exists."
else
  (
    crontab -l 2>/dev/null || true
    echo "$cron_job"
  ) | crontab -
  echo "Added a daily 04:15 renewal cron."
fi

echo "HTTPS is enabled for: ${eligible[*]}"
