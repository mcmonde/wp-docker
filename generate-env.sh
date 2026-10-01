#!/bin/bash
# Detect host RAM and CPU, write .env once, and refresh derived config.
# Re-running this script does not rotate database passwords.

set -euo pipefail

cd "$(dirname "$0")"

FPM_OVERHEAD_MB=64
WORKER_MB=80
UPLOAD_DEFAULT=128M
FASTCGI_DEFAULT=300
PHP_MEMORY_DEFAULT=256M
OPCACHE_DEFAULT=256

rand_secret() {
  local raw
  raw=$(openssl rand -base64 48 | tr -d '/+=\n')
  printf '%s' "${raw:0:32}"
}

ensure_var() {
  local key=$1
  local value=$2
  if ! grep -q "^${key}=" .env; then
    printf '%s=%s\n' "$key" "$value" >> .env
    echo "Added ${key} to .env"
  fi
}

compute_pool() {
  local wp_mb=${WP_MEM_LIMIT%[mM]}
  local opcache_mb=${OPCACHE_MEMORY_MB:-$OPCACHE_DEFAULT}
  local available=$((wp_mb - opcache_mb - FPM_OVERHEAD_MB))
  local min_needed=$((WORKER_MB * 2))

  if [ "$available" -lt "$min_needed" ]; then
    echo "WP_MEM_LIMIT=${WP_MEM_LIMIT} cannot fit OPcache (${opcache_mb}MB), ${FPM_OVERHEAD_MB}MB overhead, and 2 workers of ${WORKER_MB}MB." >&2
    exit 1
  fi

  PHP_CHILDREN=$((available / WORKER_MB))
  if [ "$PHP_CHILDREN" -gt 32 ]; then
    PHP_CHILDREN=32
  fi

  START_SERVERS=$((PHP_CHILDREN / 4))
  if [ "$START_SERVERS" -lt 1 ]; then
    START_SERVERS=1
  fi

  MIN_SPARE=$((PHP_CHILDREN / 8))
  if [ "$MIN_SPARE" -lt 1 ]; then
    MIN_SPARE=1
  fi

  MAX_SPARE=$((PHP_CHILDREN / 2))
  if [ "$MAX_SPARE" -lt "$START_SERVERS" ]; then
    MAX_SPARE=$START_SERVERS
  fi
  if [ "$MIN_SPARE" -gt "$MAX_SPARE" ]; then
    MIN_SPARE=$MAX_SPARE
  fi
  if [ "$START_SERVERS" -lt "$MIN_SPARE" ]; then
    START_SERVERS=$MIN_SPARE
  fi
  if [ "$START_SERVERS" -gt "$MAX_SPARE" ]; then
    START_SERVERS=$MAX_SPARE
  fi
}

write_wordpress_locations() {
  cat <<EOF
    root /var/www/html;
    index index.php;
    client_max_body_size ${UPLOAD_MAX};

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass wordpress:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_read_timeout ${FASTCGI_TIMEOUT}s;
        fastcgi_send_timeout ${FASTCGI_TIMEOUT}s;
    }

    location = /xmlrpc.php {
        deny all;
    }

    location ~ /\.ht {
        deny all;
    }

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        allow all;
    }

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
EOF
}

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required to generate database passwords." >&2
  exit 1
fi

if [ ! -f .env ]; then
  echo "Detecting system resources..."

  TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
  CPU_CORES=$(nproc)

  echo "Detected RAM: ${TOTAL_RAM_MB}MB"
  echo "Detected CPU: ${CPU_CORES} cores"

  # Keep 20% RAM for the OS and the Docker engine.
  SAFE_RAM_MB=$((TOTAL_RAM_MB * 80 / 100))
  echo "Usable RAM after reservation: ${SAFE_RAM_MB}MB"

  DB_MEM=$((SAFE_RAM_MB * 35 / 100))
  WP_MEM=$((SAFE_RAM_MB * 45 / 100))
  REDIS_MEM=$((SAFE_RAM_MB * 10 / 100))

  INNODB_BUFFER_POOL=$((DB_MEM * 70 / 100))
  INNODB_LOG_FILE=$((DB_MEM * 10 / 100))
  if [ "$INNODB_LOG_FILE" -lt 128 ]; then INNODB_LOG_FILE=128; fi
  if [ "$INNODB_LOG_FILE" -gt 512 ]; then INNODB_LOG_FILE=512; fi

  MAX_CONNECTIONS=$((CPU_CORES * 20))
  if [ "$MAX_CONNECTIONS" -lt 50 ]; then MAX_CONNECTIONS=50; fi
  if [ "$MAX_CONNECTIONS" -gt 200 ]; then MAX_CONNECTIONS=200; fi

  if [ "$INNODB_BUFFER_POOL" -lt 256 ]; then
    echo "Unsafe DB config detected: INNODB_BUFFER_POOL=${INNODB_BUFFER_POOL}MB" >&2
    echo "Increase server RAM or adjust allocation ratios." >&2
    exit 1
  fi
  if [ "$DB_MEM" -lt 512 ]; then
    echo "DB memory too low (${DB_MEM}MB)." >&2
    exit 1
  fi
  if [ "$REDIS_MEM" -lt 128 ]; then
    echo "Redis memory too low (${REDIS_MEM}MB)." >&2
    exit 1
  fi

  PUID=$(id -u)
  PGID=$(id -g)
  if [ "$PUID" -eq 0 ]; then
    owner_uid=$(stat -c '%u' .)
    owner_gid=$(stat -c '%g' .)
    if [ "$owner_uid" -ne 0 ]; then
      PUID=$owner_uid
      PGID=$owner_gid
    else
      PUID=1000
      PGID=1000
      echo "Running as root on a root-owned tree. Defaulting PUID/PGID to 1000. Edit .env if that is not the WordPress user."
    fi
  fi

  WP_MEM_LIMIT="${WP_MEM}m"
  OPCACHE_MEMORY_MB=$OPCACHE_DEFAULT
  compute_pool

  REDIS_MAXMEMORY="$((REDIS_MEM * 75 / 100))mb"
  MYSQL_ROOT_PASSWORD=$(rand_secret)
  MYSQL_PASSWORD=$(rand_secret)

  umask 077
  cat > .env <<EOF
PUID=${PUID}
PGID=${PGID}

PROJECT_NAME=wordpress

# Bare hostname. localhost is for HTTP-only local use.
# Certbot needs a public DNS name and no scheme.
DOMAIN=localhost

# Full site URL, including http:// or https://
WP_HOME=http://localhost

EMAIL=changeme@example.com
DB_PREFIX=wp_

# Database secrets. Generated once. Re-running this script does not rotate them.
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=wordpress
MYSQL_USER=default
MYSQL_PASSWORD=${MYSQL_PASSWORD}

# Docker memory limits
DB_MEM_LIMIT=${DB_MEM}m
WP_MEM_LIMIT=${WP_MEM}m
REDIS_MEM_LIMIT=${REDIS_MEM}m
NGINX_MEM_LIMIT=256m
REDIS_MAXMEMORY=${REDIS_MAXMEMORY}

# MariaDB tuning
INNODB_BUFFER_POOL_SIZE=${INNODB_BUFFER_POOL}M
INNODB_LOG_FILE_SIZE=${INNODB_LOG_FILE}M
MAX_CONNECTIONS=${MAX_CONNECTIONS}

# PHP and upload limits. UPLOAD_MAX is shared by PHP and Nginx.
PHP_MEMORY_LIMIT=${PHP_MEMORY_DEFAULT}
UPLOAD_MAX=${UPLOAD_DEFAULT}
FASTCGI_TIMEOUT=${FASTCGI_DEFAULT}
OPCACHE_MEMORY_MB=${OPCACHE_DEFAULT}

# PHP-FPM pool. Derived from WP_MEM_LIMIT minus OPcache and overhead.
PHP_FPM_PM_MAX_CHILDREN=${PHP_CHILDREN}
PHP_FPM_PM_START_SERVERS=${START_SERVERS}
PHP_FPM_PM_MIN_SPARE_SERVERS=${MIN_SPARE}
PHP_FPM_PM_MAX_SPARE_SERVERS=${MAX_SPARE}

# Host snapshot from the run that created this file
TOTAL_RAM_MB=${TOTAL_RAM_MB}
SAFE_RAM_MB=${SAFE_RAM_MB}
CPU_CORES=${CPU_CORES}
EOF
  umask 022
  echo "Created .env with generated database passwords."
else
  echo ".env exists. Passwords and existing values were left unchanged."
fi

chmod 600 .env

set -a
# shellcheck disable=SC1091
source .env
set +a

if [ -z "${WP_HOME:-}" ]; then
  case "${DOMAIN}" in
    *://*) WP_HOME=${DOMAIN} ;;
    *) WP_HOME="http://${DOMAIN}" ;;
  esac
  ensure_var WP_HOME "$WP_HOME"
fi

ensure_var UPLOAD_MAX "$UPLOAD_DEFAULT"
ensure_var FASTCGI_TIMEOUT "$FASTCGI_DEFAULT"
ensure_var PHP_MEMORY_LIMIT "$PHP_MEMORY_DEFAULT"
ensure_var OPCACHE_MEMORY_MB "$OPCACHE_DEFAULT"
ensure_var NGINX_MEM_LIMIT "256m"

if [ -z "${REDIS_MAXMEMORY:-}" ]; then
  redis_mb=${REDIS_MEM_LIMIT%[mM]}
  REDIS_MAXMEMORY="$((redis_mb * 75 / 100))mb"
  ensure_var REDIS_MAXMEMORY "$REDIS_MAXMEMORY"
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

if [ -z "${PHP_FPM_PM_MAX_CHILDREN:-}" ]; then
  compute_pool
  ensure_var PHP_FPM_PM_MAX_CHILDREN "$PHP_CHILDREN"
  ensure_var PHP_FPM_PM_START_SERVERS "$START_SERVERS"
  ensure_var PHP_FPM_PM_MIN_SPARE_SERVERS "$MIN_SPARE"
  ensure_var PHP_FPM_PM_MAX_SPARE_SERVERS "$MAX_SPARE"
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

db_mb=${DB_MEM_LIMIT%[mM]}
redis_mb=${REDIS_MEM_LIMIT%[mM]}
redis_max_mb=${REDIS_MAXMEMORY//[^0-9]/}
if [ "$db_mb" -lt 512 ]; then
  echo "DB_MEM_LIMIT=${DB_MEM_LIMIT} is below the 512 MB minimum." >&2
  exit 1
fi
if [ "$redis_mb" -lt 128 ]; then
  echo "REDIS_MEM_LIMIT=${REDIS_MEM_LIMIT} is below the 128 MB minimum." >&2
  exit 1
fi
if [ "$redis_max_mb" -ge "$redis_mb" ]; then
  echo "REDIS_MAXMEMORY=${REDIS_MAXMEMORY} must stay below REDIS_MEM_LIMIT=${REDIS_MEM_LIMIT} so Redis can evict keys before Docker kills it." >&2
  exit 1
fi

PHP_CHILDREN=$PHP_FPM_PM_MAX_CHILDREN
START_SERVERS=$PHP_FPM_PM_START_SERVERS
MIN_SPARE=$PHP_FPM_PM_MIN_SPARE_SERVERS
MAX_SPARE=$PHP_FPM_PM_MAX_SPARE_SERVERS

if [ "$MIN_SPARE" -gt "$MAX_SPARE" ] \
  || [ "$START_SERVERS" -lt "$MIN_SPARE" ] \
  || [ "$START_SERVERS" -gt "$MAX_SPARE" ] \
  || [ "$MAX_SPARE" -gt "$PHP_CHILDREN" ]; then
  echo "PHP-FPM values in .env are inconsistent. min spare <= start <= max spare <= max children." >&2
  exit 1
fi

umask 022
mkdir -p mysql php nginx/conf.d nginx/logs wp-content/{uploads,plugins,themes,upgrade,cache,mu-plugins,languages,backups} backups
if [ "$(id -u)" -eq 0 ]; then
  chown -R "${PUID}:${PGID}" wp-content
fi

cat > mysql/my.cnf <<EOF
[mysqld]

innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_SIZE}
innodb_log_file_size = ${INNODB_LOG_FILE_SIZE}

max_connections = ${MAX_CONNECTIONS}

innodb_flush_log_at_trx_commit = 2
innodb_file_per_table = 1
EOF

cat > php/custom.ini <<EOF
memory_limit = ${PHP_MEMORY_LIMIT}
upload_max_filesize = ${UPLOAD_MAX}
post_max_size = ${UPLOAD_MAX}
max_execution_time = ${FASTCGI_TIMEOUT}
max_input_vars = 5000

; OPcache
opcache.enable=1
opcache.memory_consumption=${OPCACHE_MEMORY_MB}
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=2

; Realpath cache
realpath_cache_size=256K
realpath_cache_ttl=600
EOF

cat > php/zz-pool.conf <<EOF
; Generated by generate-env.sh. Later files override the image pool.
[www]
pm = dynamic
pm.max_children = ${PHP_CHILDREN}
pm.start_servers = ${START_SERVERS}
pm.min_spare_servers = ${MIN_SPARE}
pm.max_spare_servers = ${MAX_SPARE}
pm.max_requests = 500
EOF

{
  echo "# Generated by generate-env.sh."
  echo "server {"
  echo "    listen 80;"
  echo "    server_name _;"
  write_wordpress_locations
  echo "}"
} > nginx/conf.d/default.conf

{
  echo "# Generated by generate-env.sh."
  echo "server {"
  echo "    listen 443 ssl;"
  echo "    http2 on;"
  echo "    server_name ${DOMAIN};"
  echo
  echo "    ssl_certificate     /etc/nginx/certs/live/${DOMAIN}/fullchain.pem;"
  echo "    ssl_certificate_key /etc/nginx/certs/live/${DOMAIN}/privkey.pem;"
  echo "    ssl_protocols TLSv1.2 TLSv1.3;"
  echo "    ssl_session_cache shared:SSL:10m;"
  echo "    ssl_session_timeout 1d;"
  echo "    ssl_session_tickets off;"
  echo
  write_wordpress_locations
  echo "}"
} > nginx/conf.d/ssl.conf

cat > nginx/conf.d/http-redirect.conf <<EOF
# Generated by generate-env.sh. Mounted over default.conf when HTTPS is enabled.
server {
    listen 80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

chmod 644 mysql/my.cnf php/custom.ini php/zz-pool.conf \
  nginx/conf.d/default.conf nginx/conf.d/ssl.conf nginx/conf.d/http-redirect.conf

echo "Wrote mysql/my.cnf, php/custom.ini, php/zz-pool.conf, and nginx/conf.d."

./cron-setup.sh
