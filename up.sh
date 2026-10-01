#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f docker-compose.sites.yml ]; then
  echo "Run ./generate-env.sh first." >&2
  exit 1
fi

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

docker compose up -d --remove-orphans
./provision-sites.sh
