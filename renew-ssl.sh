#!/bin/bash
# Renew the Let's Encrypt certificate and reload Nginx.
# enable-ssl.sh installs this on a daily cron.

set -euo pipefail

cd "$(dirname "$0")"

docker compose --profile ssl run --rm certbot renew \
  --webroot -w /var/www/letsencrypt \
  --quiet

docker compose exec -T nginx nginx -s reload
