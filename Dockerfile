# WordPress PHP-FPM plus WP-CLI and the Redis Object Cache plugin.
# The plugin is installed outside /var/www/html/wp-content because Compose
# bind-mounts that directory from the host.
FROM wordpress:7.1.0-php8.5-fpm-alpine

ARG REDIS_CACHE_VERSION=3.0.0

RUN apk add --no-cache less mariadb-client unzip \
    && curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /usr/local/bin/wp \
    && curl -fsSL -o /tmp/redis-cache.zip "https://downloads.wordpress.org/plugin/redis-cache.${REDIS_CACHE_VERSION}.zip" \
    && unzip -q /tmp/redis-cache.zip -d /opt \
    && rm /tmp/redis-cache.zip \
    && test -f /opt/redis-cache/includes/object-cache.php \
    && test -f /opt/redis-cache/dependencies/predis/predis/autoload.php \
    && chmod -R a+rX /opt/redis-cache

COPY docker-entrypoint-wrapper.sh /usr/local/bin/wp-stack-entrypoint.sh
RUN chmod +x /usr/local/bin/wp-stack-entrypoint.sh

ENTRYPOINT ["wp-stack-entrypoint.sh"]
CMD ["php-fpm"]
