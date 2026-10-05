#!/bin/bash
# Add a WordPress site, then regenerate Compose, Nginx, and database config.
# Usage: ./wpd site:add SITE_ID DOMAIN [WP_HOME|ALLOCATION_WEIGHT] [ALLOCATION_WEIGHT]
# Refused when the server is over capacity; prefix with FORCE_SITES=yes to override (e.g. benchmarks).

set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo "Usage: ./wpd site:add SITE_ID DOMAIN [WP_HOME|ALLOCATION_WEIGHT] [ALLOCATION_WEIGHT]" >&2
  exit 1
fi

site_id=$1
domain=$2
wp_home="http://${domain}"
weight=1
if [ "$#" -ge 3 ]; then
  if [[ "$3" =~ ^[1-9][0-9]*$ ]]; then
    weight=$3
  else
    wp_home=$3
  fi
fi
if [ "$#" -ge 4 ]; then
  weight=$4
fi

if [[ ! "$site_id" =~ ^[a-z][a-z0-9_]{0,15}$ ]]; then
  echo "SITE_ID must start with a letter and use only lowercase letters, numbers, and underscores (16 characters max)." >&2
  exit 1
fi

case "$site_id" in
  db|nginx|redis|certbot|phpmyadmin)
    echo "SITE_ID '${site_id}' is reserved." >&2
    exit 1
    ;;
esac

if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || [[ "$domain" == *..* ]]; then
  echo "DOMAIN must be a hostname, for example blog.example.com." >&2
  exit 1
fi

case "$wp_home" in
  http://*|https://*) ;;
  *)
    echo "WP_HOME must start with http:// or https://." >&2
    exit 1
    ;;
esac

if [[ ! "$weight" =~ ^[1-9][0-9]*$ ]]; then
  echo "ALLOCATION_WEIGHT must be a positive integer. 1 is a fair share. 2 is twice a weight-1 site." >&2
  exit 1
fi

if [ -f "sites/${site_id}.env" ]; then
  echo "Site '${site_id}' already exists at sites/${site_id}.env." >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required to generate a database password." >&2
  exit 1
fi

raw=$(openssl rand -base64 48 | tr -d '/+=\n')
db_password=${raw:0:32}

mkdir -p sites
umask 077
cat > "sites/${site_id}.env" <<EOF
DOMAIN=${domain}
WP_HOME=${wp_home}
DB_NAME=${site_id}
DB_USER=${site_id}
DB_PASSWORD=${db_password}
DB_PREFIX=wp_
ALLOCATION_WEIGHT=${weight}
EOF
chmod 600 "sites/${site_id}.env"
umask 022

echo "Created sites/${site_id}.env."
if ! bin/generate-env.sh; then
  rm -f "sites/${site_id}.env"
  echo "Removed sites/${site_id}.env because env:generate failed. Nothing was added." >&2
  exit 1
fi
echo "Site '${site_id}' is configured. Start it with ./wpd up"
