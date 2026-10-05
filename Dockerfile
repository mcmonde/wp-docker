# WordPress PHP-FPM plus WP-CLI and the Redis Object Cache plugin.
# The plugin is installed outside /var/www/html/wp-content because Compose
# bind-mounts that directory from the host.
FROM wordpress:7.1.2-php8.5-fpm-alpine

# Bump a version together with its checksum. WP-CLI publishes its SHA-512 next to each
# release; WordPress.org publishes none for plugin zips, so that SHA-256 was taken from
# the downloaded file.
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832
ARG REDIS_CACHE_VERSION=3.0.0
ARG REDIS_CACHE_SHA256=7a03342d3defbe94cac8d0470b42dc1a1c34331b19c47205df20ceccd3c8f54a

RUN apk add --no-cache less mariadb-client unzip fcgi \
    && curl -fsSL -o /usr/local/bin/wp "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
    && echo "${WP_CLI_SHA512}  /usr/local/bin/wp" | sha512sum -c - \
    && chmod +x /usr/local/bin/wp \
    && curl -fsSL -o /tmp/redis-cache.zip "https://downloads.wordpress.org/plugin/redis-cache.${REDIS_CACHE_VERSION}.zip" \
    && echo "${REDIS_CACHE_SHA256}  /tmp/redis-cache.zip" | sha256sum -c - \
    && unzip -q /tmp/redis-cache.zip -d /opt \
    && rm /tmp/redis-cache.zip \
    && test -f /opt/redis-cache/includes/object-cache.php \
    && test -f /opt/redis-cache/dependencies/predis/predis/autoload.php \
    && chmod -R a+rX /opt/redis-cache

COPY plugins/do-spaces-uploads /opt/do-spaces-uploads
RUN chmod -R a+rX /opt/do-spaces-uploads

COPY docker-entrypoint-wrapper.sh /usr/local/bin/wp-stack-entrypoint.sh
RUN chmod +x /usr/local/bin/wp-stack-entrypoint.sh

# Asks PHP-FPM itself for its ping page (ping.path in the generated pool), so a hung pool turns unhealthy.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD SCRIPT_NAME=/fpm-ping SCRIPT_FILENAME=/fpm-ping REQUEST_METHOD=GET \
        cgi-fcgi -bind -connect 127.0.0.1:9000 | grep -q pong || exit 1

ENTRYPOINT ["wp-stack-entrypoint.sh"]
CMD ["php-fpm"]
