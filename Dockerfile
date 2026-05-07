# Use the latest stable WordPress image with PHP 8.4 FPM and Alpine
FROM wordpress:6.9.4-php8.4-fpm-alpine

# 1. Install OS dependencies (mariadb-client, less, etc.)
RUN apk add --no-cache less mariadb-client

# 2. Install WP-CLI (WordPress CLI)
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

# 3. Copy custom themes and plugins (optional step; uncomment if needed)
#COPY --chown=www-data:www-data ./wp-content/themes /var/www/html/wp-content/themes
#COPY --chown=www-data:www-data ./wp-content/plugins /var/www/html/wp-content/plugins

# 4. Secure permissions for WordPress content directory
USER root
RUN chmod -R 755 /var/www/html/wp-content
USER www-data