FROM wordpress:6-php8.2-fpm-alpine

# 1. Install OS dependencies (Less & Database Client)
RUN apk add --no-cache less mariadb-client

# 2. Install WP-CLI
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

# 3. Copy your Themes and Plugins
COPY --chown=www-data:www-data ./wp-content/themes /var/www/html/wp-content/themes
COPY --chown=www-data:www-data ./wp-content/plugins /var/www/html/wp-content/plugins

# 4. Copy PHP Config
COPY ./php/uploads.ini /usr/local/etc/php/conf.d/uploads.ini

# 5. Secure permissions
USER root
RUN chmod -R 755 /var/www/html/wp-content
USER www-data