#!/bin/bash

set -a
source .env
set +a

OLD_URL="https://domain.com"
NEW_URL="http://192.168.1.1"

# Standard replace
docker exec -it -u www-data ${PROJECT_NAME}_app \
wp search-replace "$OLD_URL" "$NEW_URL" --all-tables --skip-columns=guid --allow-root

# Check if Elementor is installed
if docker exec -u www-data ${PROJECT_NAME}_app wp plugin is-installed elementor > /dev/null 2>&1; then
    echo "Elementor detected. Running Elementor URL replacement..."

    docker exec -it -u www-data ${PROJECT_NAME}_app \
    wp elementor replace-urls "$OLD_URL" "$NEW_URL" --allow-root

    docker exec -it -u www-data ${PROJECT_NAME}_app \
    wp elementor flush-css --allow-root
else
    echo "Elementor not installed. Skipping..."
fi