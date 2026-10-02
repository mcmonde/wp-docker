#!/bin/bash
# Detect host RAM and CPU, write stack .env once, and refresh one
# PHP container and Nginx vhost per site. One MariaDB holds every site
# database. Re-running does not rotate passwords or WordPress keys.

set -euo pipefail

cd "$(dirname "$0")"
shopt -s nullglob

FORCE_SITES_CLI=${FORCE_SITES:-}

UPLOAD_DEFAULT=128M
FASTCGI_DEFAULT=300
PHP_MEMORY_DEFAULT=256M
OPCACHE_DEFAULT=128
PHP_WORKER_AVG_DEFAULT=80
WORKERS_PER_CPU_DEFAULT=4
PHP_FPM_PM_DEFAULT=ondemand

# Site capacity standard. The first site needs 1 vCPU and a 2 GB server (which reports
# ~1960MB in `free -m`). Each additional weight-1 site needs another 0.5 vCPU and 512MB.
BASE_SITE_CPU_MILLI=1000
BASE_SITE_RAM_MB=1800
EXTRA_SITE_CPU_MILLI=500
EXTRA_SITE_RAM_MB=512

MIN_SITE_WORKERS=2
MAX_SITE_WORKERS=50
FPM_MASTER_MB=32
OS_RESERVE_MB=384
NGINX_RESERVE_MB=128

rand_secret() {
  local length=${1:-32}
  local raw
  raw=$(openssl rand -base64 96 | tr -d '/+=\n')
  printf '%s' "${raw:0:length}"
}

WP_SECRET_KEYS=(
  AUTH_KEY
  SECURE_AUTH_KEY
  LOGGED_IN_KEY
  NONCE_KEY
  AUTH_SALT
  SECURE_AUTH_SALT
  LOGGED_IN_SALT
  NONCE_SALT
)

ensure_var() {
  local key=$1
  local value=$2
  if ! grep -q "^${key}=" .env; then
    printf '%s=%s\n' "$key" "$value" >> .env
    echo "Added ${key} to .env"
  fi
}

set_env_var() {
  local key=$1
  local value=$2
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

upsert_file_var() {
  local file=$1
  local key=$2
  local value=$3
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

site_get() {
  local file=$1
  local key=$2
  local line
  line=$(grep -E "^${key}=" "$file" | tail -n 1 || true)
  printf '%s' "${line#*=}"
}

secret_needs_generation() {
  local value=$1
  local lower
  lower=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    ""|change-me|changeme|password|secret|your-password|example) return 0 ;;
  esac
  [ "${#value}" -lt 16 ]
}

ensure_site_secret() {
  local file=$1
  local key=$2
  local length=$3
  local current
  current=$(site_get "$file" "$key")
  if secret_needs_generation "$current"; then
    current=$(rand_secret "$length")
    upsert_file_var "$file" "$key" "$current"
  fi
}

# Empty values are only filled while Spaces is disabled, so a live config is never rewritten.
ensure_spaces_var() {
  local file=$1
  local key=$2
  local default_value=$3
  local enabled
  if ! grep -q "^${key}=" "$file"; then
    upsert_file_var "$file" "$key" "$default_value"
    return
  fi
  enabled=$(site_get "$file" SPACES_ENABLED | tr '[:upper:]' '[:lower:]')
  if [ "$enabled" != "yes" ] && [ -z "$(site_get "$file" "$key")" ]; then
    upsert_file_var "$file" "$key" "$default_value"
  fi
}

SPACES_KEY_PLACEHOLDER=your-key-do-space-here
SPACES_SECRET_PLACEHOLDER=your-secret-do-space-here
SPACES_BUCKET_PLACEHOLDER=bucket-name-here

ensure_spaces_vars() {
  local site_file=$1
  local site_id=$2
  ensure_spaces_var "$site_file" SPACES_ENABLED "no"
  ensure_spaces_var "$site_file" SPACES_KEY "$SPACES_KEY_PLACEHOLDER"
  ensure_spaces_var "$site_file" SPACES_SECRET "$SPACES_SECRET_PLACEHOLDER"
  ensure_spaces_var "$site_file" SPACES_BUCKET "$SPACES_BUCKET_PLACEHOLDER"
  ensure_spaces_var "$site_file" SPACES_REGION "sgp1"
  ensure_spaces_var "$site_file" SPACES_ENDPOINT "https://SPACES_BUCKET.SPACES_REGION.digitaloceanspaces.com"
  ensure_spaces_var "$site_file" SPACES_PUBLIC_URL "https://SPACES_BUCKET.SPACES_REGION.cdn.digitaloceanspaces.com"
  ensure_spaces_var "$site_file" SPACES_PREFIX "$site_id"
  ensure_spaces_var "$site_file" SPACES_PATH_STYLE "no"
}

# SPACES_BUCKET and SPACES_REGION are literal uppercase tokens; bucket names are lowercase, so they cannot collide.
expand_spaces_tokens() {
  local value=$1
  local bucket=$2
  local region=$3
  value=${value//SPACES_BUCKET/$bucket}
  value=${value//SPACES_REGION/$region}
  printf '%s' "$value"
}

sql_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

php_sq() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\'/\\\'}
  printf '%s' "$value"
}

yaml_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//\$/\$\$}
  printf '"%s"' "$value"
}

content_dir_for() {
  printf '%s' "sites/$1/wp-content"
}

valid_site_id() {
  local id=$1
  [[ "$id" =~ ^[a-z][a-z0-9_]{0,15}$ ]] || return 1
  case "$id" in
    db|nginx|redis|certbot|phpmyadmin) return 1 ;;
  esac
  return 0
}

ask_allocation() {
  local answer
  if [ -t 0 ]; then
    echo "Enable fair CPU and RAM limits for each WordPress site?"
    echo "Yes splits the WordPress RAM and CPU budget by site weight and recalculates it when a site is added."
    echo "No leaves WordPress containers without CPU or RAM limits."
    read -r -p "Enable allocation? [Y/n] " answer
    case "${answer,,}" in
      n|no) ALLOCATE_RESOURCES=no ;;
      y|yes|"") ALLOCATE_RESOURCES=yes ;;
      *)
        echo "Answer yes or no." >&2
        exit 1
        ;;
    esac
  else
    ALLOCATE_RESOURCES=yes
    echo "ALLOCATE_RESOURCES was not set. Defaulting to yes. Set it to no in .env to leave WordPress containers unlimited."
  fi
  echo "Allocation is ${ALLOCATE_RESOURCES}."
}

format_cpus() {
  local milli=$1
  printf '%d.%03d' $((milli / 1000)) $((milli % 1000))
}

memory_limit_mb() {
  local raw=${1:-256M}
  local mb=${raw//[^0-9]/}
  if [ -z "$mb" ] || [ "$mb" -lt 1 ]; then
    mb=128
  fi
  printf '%s' "$mb"
}

# Prints how many weight-1 sites this host can run under the capacity standard.
site_capacity() {
  local ram_mb=$1
  local cpu_milli=$2
  local by_cpu
  local by_ram
  if [ "$ram_mb" -lt "$BASE_SITE_RAM_MB" ] || [ "$cpu_milli" -lt "$BASE_SITE_CPU_MILLI" ]; then
    printf '0'
    return
  fi
  by_cpu=$(((cpu_milli - BASE_SITE_CPU_MILLI) / EXTRA_SITE_CPU_MILLI))
  by_ram=$(((ram_mb - BASE_SITE_RAM_MB) / EXTRA_SITE_RAM_MB))
  if [ "$by_cpu" -lt "$by_ram" ]; then
    printf '%s' $((1 + by_cpu))
  else
    printf '%s' $((1 + by_ram))
  fi
}

# Sizes MariaDB, Redis, and the WordPress budget for `units` total site weight.
# Uses TOTAL_RAM_MB, CPU_CORES, and WORKERS_PER_CPU.
auto_size_services() {
  local units=$1
  local worker_cap=$((WORKERS_PER_CPU * CPU_CORES))
  local min_workers=$((MIN_SITE_WORKERS * units))
  local buffer_cap=$((TOTAL_RAM_MB / 4))
  local opcache_mb
  local worker_avg_mb=${PHP_WORKER_AVG_MB:-$PHP_WORKER_AVG_DEFAULT}
  local max_workers
  local conn_est
  local php_need
  local spare
  opcache_mb=$(memory_limit_mb "${OPCACHE_MEMORY_MB:-$OPCACHE_DEFAULT}")

  REDIS_MEM=$((64 + 32 * units))
  if [ "$REDIS_MEM" -lt 128 ]; then REDIS_MEM=128; fi
  if [ "$REDIS_MEM" -gt 512 ]; then REDIS_MEM=512; fi
  REDIS_MAXMEMORY="$((REDIS_MEM * 75 / 100))mb"

  INNODB_BUFFER_POOL=$((256 + 64 * units))
  if [ "$INNODB_BUFFER_POOL" -gt "$buffer_cap" ]; then INNODB_BUFFER_POOL=$buffer_cap; fi
  if [ "$INNODB_BUFFER_POOL" -lt 256 ]; then INNODB_BUFFER_POOL=256; fi

  # Each PHP worker holds one connection; roughly 2MB per connection plus server overhead.
  max_workers=$worker_cap
  if [ "$min_workers" -gt "$max_workers" ]; then max_workers=$min_workers; fi
  conn_est=$((max_workers + 20))
  if [ "$conn_est" -lt 30 ]; then conn_est=30; fi
  NGINX_MEM=$NGINX_RESERVE_MB

  # PHP can only use CPU-limited workers, so RAM beyond that is split between
  # a larger InnoDB buffer pool (up to a quarter of RAM) and WordPress headroom.
  php_need=$((max_workers * worker_avg_mb + units * (opcache_mb + FPM_MASTER_MB)))
  spare=$((TOTAL_RAM_MB - OS_RESERVE_MB - NGINX_MEM - REDIS_MEM - INNODB_BUFFER_POOL - 192 - 2 * conn_est - php_need))
  if [ "$spare" -gt 0 ]; then
    INNODB_BUFFER_POOL=$((INNODB_BUFFER_POOL + spare / 2))
    if [ "$INNODB_BUFFER_POOL" -gt "$buffer_cap" ]; then INNODB_BUFFER_POOL=$buffer_cap; fi
  fi
  INNODB_LOG_FILE=$((INNODB_BUFFER_POOL / 4))
  if [ "$INNODB_LOG_FILE" -lt 128 ]; then INNODB_LOG_FILE=128; fi
  if [ "$INNODB_LOG_FILE" -gt 512 ]; then INNODB_LOG_FILE=512; fi
  DB_MEM=$((INNODB_BUFFER_POOL + 192 + 2 * conn_est))

  WP_MEM=$((TOTAL_RAM_MB - OS_RESERVE_MB - NGINX_MEM - REDIS_MEM - DB_MEM))
  if [ "$WP_MEM" -lt 1 ]; then WP_MEM=1; fi
  WP_CPU_MILLICORES=$((CPU_CORES * 800))
}

# Sets PHP_CHILDREN and the dynamic-mode spare counts for one site.
# Workers are bounded by RAM (average worker size) and by the site's share of CPU workers.
size_site_pool() {
  local share_mb=$1
  local cpu_workers=$2
  local ram_workers
  ram_workers=$(((share_mb - OPCACHE_MB - FPM_MASTER_MB) / PHP_WORKER_AVG_MB))
  PHP_CHILDREN=$ram_workers
  if [ "$cpu_workers" -lt "$PHP_CHILDREN" ]; then PHP_CHILDREN=$cpu_workers; fi
  if [ "$PHP_CHILDREN" -lt "$MIN_SITE_WORKERS" ]; then PHP_CHILDREN=$MIN_SITE_WORKERS; fi
  if [ "$PHP_CHILDREN" -gt "$MAX_SITE_WORKERS" ]; then PHP_CHILDREN=$MAX_SITE_WORKERS; fi

  START_SERVERS=$((PHP_CHILDREN / 4))
  if [ "$START_SERVERS" -lt 1 ]; then START_SERVERS=1; fi

  MIN_SPARE=$((PHP_CHILDREN / 8))
  if [ "$MIN_SPARE" -lt 1 ]; then MIN_SPARE=1; fi

  MAX_SPARE=$((PHP_CHILDREN / 2))
  if [ "$MAX_SPARE" -lt "$START_SERVERS" ]; then MAX_SPARE=$START_SERVERS; fi
  if [ "$MIN_SPARE" -gt "$MAX_SPARE" ]; then MIN_SPARE=$MAX_SPARE; fi
  if [ "$START_SERVERS" -lt "$MIN_SPARE" ]; then START_SERVERS=$MIN_SPARE; fi
  if [ "$START_SERVERS" -gt "$MAX_SPARE" ]; then START_SERVERS=$MAX_SPARE; fi
}

spaces_config_extra() {
  local site_file=$1
  local id=$2
  local enabled key secret bucket region endpoint public_url prefix path_style

  enabled=$(site_get "$site_file" SPACES_ENABLED)
  enabled=$(printf '%s' "$enabled" | tr '[:upper:]' '[:lower:]')
  if [ "$enabled" != "yes" ]; then
    echo "        define('DO_SPACES_ENABLED', false);"
    return
  fi

  key=$(site_get "$site_file" SPACES_KEY)
  secret=$(site_get "$site_file" SPACES_SECRET)
  bucket=$(site_get "$site_file" SPACES_BUCKET)
  region=$(site_get "$site_file" SPACES_REGION)
  endpoint=$(site_get "$site_file" SPACES_ENDPOINT)
  public_url=$(site_get "$site_file" SPACES_PUBLIC_URL)
  prefix=$(site_get "$site_file" SPACES_PREFIX)
  path_style=$(site_get "$site_file" SPACES_PATH_STYLE)
  path_style=$(printf '%s' "$path_style" | tr '[:upper:]' '[:lower:]')

  if [ -z "$prefix" ]; then
    prefix=$id
    upsert_file_var "$site_file" SPACES_PREFIX "$prefix"
  fi

  if [ -z "$key" ] || [ -z "$secret" ] || [ -z "$bucket" ] || [ -z "$region" ] \
    || [ "$key" = "$SPACES_KEY_PLACEHOLDER" ] || [ "$secret" = "$SPACES_SECRET_PLACEHOLDER" ] \
    || [ "$bucket" = "$SPACES_BUCKET_PLACEHOLDER" ]; then
    echo "Site '${id}' has SPACES_ENABLED=yes but SPACES_KEY, SPACES_SECRET, SPACES_BUCKET, and SPACES_REGION must be set to real values in sites/${id}.env." >&2
    exit 1
  fi

  endpoint=$(expand_spaces_tokens "$endpoint" "$bucket" "$region")
  public_url=$(expand_spaces_tokens "$public_url" "$bucket" "$region")

  cat <<EOF
        define('DO_SPACES_ENABLED', true);
        define('DO_SPACES_KEY', '$(php_sq "$key")');
        define('DO_SPACES_SECRET', '$(php_sq "$secret")');
        define('DO_SPACES_BUCKET', '$(php_sq "$bucket")');
        define('DO_SPACES_REGION', '$(php_sq "$region")');
        define('DO_SPACES_PREFIX', '$(php_sq "$prefix")');
EOF
  if [ -n "$endpoint" ]; then
    echo "        define('DO_SPACES_ENDPOINT', '$(php_sq "$endpoint")');"
  fi
  if [ -n "$public_url" ]; then
    echo "        define('DO_SPACES_PUBLIC_URL', '$(php_sq "$public_url")');"
  fi
  if [ "$path_style" = "yes" ]; then
    echo "        define('DO_SPACES_PATH_STYLE', true);"
  fi
}

write_security_headers() {
  cat <<'EOF'
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
EOF
}

write_fastcgi_php() {
  local id=$1
  local https_extra=${2:-}
  cat <<EOF
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        set \$php_backend ${id};
        fastcgi_pass \$php_backend:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /var/www/html\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_read_timeout ${FASTCGI_TIMEOUT}s;
        fastcgi_send_timeout ${FASTCGI_TIMEOUT}s;
${https_extra}
EOF
}

write_php_locations() {
  local id=$1
  cat <<EOF
    resolver 127.0.0.11 valid=10s ipv6=off;
    root /var/www/sites/${id};
    index index.php;
    client_max_body_size ${UPLOAD_MAX};

$(write_security_headers)
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /wp-login.php {
        limit_req zone=wp_login burst=5 nodelay;
$(write_security_headers)
$(write_fastcgi_php "$id")
    }

    location ~ \.php\$ {
$(write_security_headers)
$(write_fastcgi_php "$id")
    }

    location = /xmlrpc.php { deny all; }
    location = /wp-config.php { deny all; }
    location ~ /\.ht { deny all; }

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        allow all;
    }

    access_log /var/log/nginx/${id}.access.log;
    error_log /var/log/nginx/${id}.error.log;
EOF
}

ensure_default_site() {
  local files=(sites/*.env)
  if [ "${#files[@]}" -gt 0 ]; then
    return
  fi

  local domain=${DOMAIN:-localhost}
  local home=${WP_HOME:-http://localhost}
  local db_name=${MYSQL_DATABASE:-wordpress}
  local db_user=${MYSQL_USER:-default}
  local db_pass=${MYSQL_PASSWORD:-$(rand_secret)}
  local prefix=${DB_PREFIX:-wp_}

  mkdir -p sites
  umask 077
  cat > sites/default.env <<EOF
DOMAIN=${domain}
WP_HOME=${home}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_pass}
DB_PREFIX=${prefix}
ALLOCATION_WEIGHT=1
EOF
  chmod 600 sites/default.env
  umask 022
  echo "Created sites/default.env from the stack settings."
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

  WORKERS_PER_CPU=$WORKERS_PER_CPU_DEFAULT
  auto_size_services 1
  MAX_CONNECTIONS=50

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
      echo "Running as root on a root-owned tree. Defaulting PUID/PGID to 1000."
    fi
  fi

  MYSQL_ROOT_PASSWORD=$(rand_secret)
  REDIS_PASSWORD=$(rand_secret)
  ask_allocation

  umask 077
  cat > .env <<EOF
PUID=${PUID}
PGID=${PGID}

PROJECT_NAME=wordpress
EMAIL=changeme@example.com

# MariaDB root password. Generated once. Site passwords live in sites/<id>.env.
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}

# AUTO_TUNE=yes re-detects host RAM and CPU on every ./generate-env.sh run and rewrites the
# MariaDB, Redis, Nginx, and WordPress budget values below for the current site count.
# Set AUTO_TUNE=no to keep hand-edited values.
AUTO_TUNE=yes

# ALLOCATE_RESOURCES=yes sets Docker RAM/CPU caps on each WordPress container by weight.
# ALLOCATE_RESOURCES=no omits those caps. Worker sizing is the same either way.
DB_MEM_LIMIT=${DB_MEM}m
WP_MEM_LIMIT=${WP_MEM}m
REDIS_MEM_LIMIT=${REDIS_MEM}m
NGINX_MEM_LIMIT=${NGINX_MEM}m
REDIS_MAXMEMORY=${REDIS_MAXMEMORY}
ALLOCATE_RESOURCES=${ALLOCATE_RESOURCES}
WP_CPU_MILLICORES=${WP_CPU_MILLICORES}

INNODB_BUFFER_POOL_SIZE=${INNODB_BUFFER_POOL}M
INNODB_LOG_FILE_SIZE=${INNODB_LOG_FILE}M
MAX_CONNECTIONS=${MAX_CONNECTIONS}

# PHP_MEMORY_LIMIT is a per-request ceiling. Workers are counted from PHP_WORKER_AVG_MB,
# the typical memory one worker uses (80 for most sites, 120+ for WooCommerce/page builders).
PHP_MEMORY_LIMIT=${PHP_MEMORY_DEFAULT}
PHP_WORKER_AVG_MB=${PHP_WORKER_AVG_DEFAULT}
WORKERS_PER_CPU=${WORKERS_PER_CPU_DEFAULT}
# ondemand starts workers on request and stops idle ones; dynamic keeps spare workers running.
PHP_FPM_PM=${PHP_FPM_PM_DEFAULT}
UPLOAD_MAX=${UPLOAD_DEFAULT}
FASTCGI_TIMEOUT=${FASTCGI_DEFAULT}
OPCACHE_MEMORY_MB=${OPCACHE_DEFAULT}

# Host snapshot, refreshed on every run.
TOTAL_RAM_MB=${TOTAL_RAM_MB}
CPU_CORES=${CPU_CORES}
EOF
  umask 022
  echo "Created .env with a generated MariaDB root password."
else
  echo ".env exists. Passwords and existing values were left unchanged."
fi

chmod 600 .env

set -a
# shellcheck disable=SC1091
source .env
set +a

ensure_var UPLOAD_MAX "$UPLOAD_DEFAULT"
ensure_var FASTCGI_TIMEOUT "$FASTCGI_DEFAULT"
ensure_var PHP_MEMORY_LIMIT "$PHP_MEMORY_DEFAULT"
ensure_var OPCACHE_MEMORY_MB "$OPCACHE_DEFAULT"
ensure_var NGINX_MEM_LIMIT "256m"
ensure_var AUTO_TUNE yes
ensure_var PHP_WORKER_AVG_MB "$PHP_WORKER_AVG_DEFAULT"
ensure_var WORKERS_PER_CPU "$WORKERS_PER_CPU_DEFAULT"
ensure_var PHP_FPM_PM "$PHP_FPM_PM_DEFAULT"

if [ -z "${ALLOCATE_RESOURCES:-}" ]; then
  ask_allocation
  ensure_var ALLOCATE_RESOURCES "$ALLOCATE_RESOURCES"
fi

if [ -z "${WP_CPU_MILLICORES:-}" ]; then
  detect_cores=${CPU_CORES:-$(nproc)}
  WP_CPU_MILLICORES=$((detect_cores * 800))
  ensure_var WP_CPU_MILLICORES "$WP_CPU_MILLICORES"
fi

if [ -z "${REDIS_MAXMEMORY:-}" ]; then
  redis_mb=${REDIS_MEM_LIMIT%[mM]}
  REDIS_MAXMEMORY="$((redis_mb * 75 / 100))mb"
  ensure_var REDIS_MAXMEMORY "$REDIS_MAXMEMORY"
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

if secret_needs_generation "${MYSQL_ROOT_PASSWORD:-}"; then
  MYSQL_ROOT_PASSWORD=$(rand_secret 32)
  set_env_var MYSQL_ROOT_PASSWORD "$MYSQL_ROOT_PASSWORD"
  chmod 600 .env
fi

if secret_needs_generation "${REDIS_PASSWORD:-}"; then
  REDIS_PASSWORD=$(rand_secret 32)
  set_env_var REDIS_PASSWORD "$REDIS_PASSWORD"
  chmod 600 .env
fi

TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
CPU_CORES=$(nproc)
set_env_var TOTAL_RAM_MB "$TOTAL_RAM_MB"
set_env_var CPU_CORES "$CPU_CORES"

db_mb=${DB_MEM_LIMIT%[mM]}
redis_mb=${REDIS_MEM_LIMIT%[mM]}
redis_max_mb=${REDIS_MAXMEMORY//[^0-9]/}
total_wp_mb=${WP_MEM_LIMIT%[mM]}

ALLOCATE_RESOURCES=$(printf '%s' "$ALLOCATE_RESOURCES" | tr '[:upper:]' '[:lower:]')
case "$ALLOCATE_RESOURCES" in
  yes|no) ;;
  *)
    echo "ALLOCATE_RESOURCES must be yes or no." >&2
    exit 1
    ;;
esac
set_env_var ALLOCATE_RESOURCES "$ALLOCATE_RESOURCES"

AUTO_TUNE=$(printf '%s' "$AUTO_TUNE" | tr '[:upper:]' '[:lower:]')
case "$AUTO_TUNE" in
  yes|no) ;;
  *)
    echo "AUTO_TUNE must be yes or no." >&2
    exit 1
    ;;
esac

PHP_FPM_PM=$(printf '%s' "$PHP_FPM_PM" | tr '[:upper:]' '[:lower:]')
case "$PHP_FPM_PM" in
  ondemand|dynamic) ;;
  *)
    echo "PHP_FPM_PM must be ondemand or dynamic." >&2
    exit 1
    ;;
esac

if [[ ! "$PHP_WORKER_AVG_MB" =~ ^[0-9]+$ ]] || [ "$PHP_WORKER_AVG_MB" -lt 16 ]; then
  echo "PHP_WORKER_AVG_MB must be a whole number of MB, 16 or more." >&2
  exit 1
fi
if [[ ! "$WORKERS_PER_CPU" =~ ^[0-9]+$ ]] || [ "$WORKERS_PER_CPU" -lt 1 ] || [ "$WORKERS_PER_CPU" -gt 16 ]; then
  echo "WORKERS_PER_CPU must be between 1 and 16." >&2
  exit 1
fi

# FORCE_SITES=yes on the command line or in .env allows more sites than the capacity standard.
FORCE_SITES=${FORCE_SITES_CLI:-${FORCE_SITES:-no}}
FORCE_SITES=$(printf '%s' "$FORCE_SITES" | tr '[:upper:]' '[:lower:]')
case "$FORCE_SITES" in
  yes|no) ;;
  *)
    echo "FORCE_SITES must be yes or no." >&2
    exit 1
    ;;
esac

OPCACHE_MB=$(memory_limit_mb "$OPCACHE_MEMORY_MB")
PHP_LIMIT_MB=$(memory_limit_mb "$PHP_MEMORY_LIMIT")

if [ "$AUTO_TUNE" = "no" ]; then
  if [[ ! "${WP_CPU_MILLICORES}" =~ ^[1-9][0-9]*$ ]]; then
    echo "WP_CPU_MILLICORES must be a positive integer. 1000 equals 1 CPU." >&2
    exit 1
  fi
  if [ "$db_mb" -lt 512 ]; then
    echo "DB_MEM_LIMIT=${DB_MEM_LIMIT} is below the 512 MB minimum." >&2
    exit 1
  fi
  if [ "$redis_mb" -lt 128 ]; then
    echo "REDIS_MEM_LIMIT=${REDIS_MEM_LIMIT} is below the 128 MB minimum." >&2
    exit 1
  fi
  if [ "$redis_max_mb" -ge "$redis_mb" ]; then
    echo "REDIS_MAXMEMORY=${REDIS_MAXMEMORY} must stay below REDIS_MEM_LIMIT=${REDIS_MEM_LIMIT}." >&2
    exit 1
  fi
fi

ensure_default_site

mapfile -t site_files < <(printf '%s\n' sites/*.env | sort)
SITE_COUNT=${#site_files[@]}
if [ "$SITE_COUNT" -lt 1 ]; then
  echo "No sites found in sites/*.env." >&2
  exit 1
fi

declare -a SITE_IDS=() SITE_DOMAINS=() SITE_HOMES=() SITE_DB_NAMES=() SITE_DB_USERS=()
declare -a SITE_DB_PASSES=() SITE_DB_PREFIXES=() SITE_WEIGHTS=() SITE_MEMS=() SITE_CPUS=()
declare -a SITE_CHILDREN=() SITE_STARTS=() SITE_MINS=() SITE_MAXS=() SITE_CONTENTS=() SITE_SSL=()
declare -A SEEN_DOMAIN=() SEEN_DB=() SEEN_USER=()

for site_file in "${site_files[@]}"; do
  site_id=$(basename "$site_file" .env)
  if ! valid_site_id "$site_id"; then
    echo "Invalid site id '${site_id}'. Use a short lowercase name, not a reserved service name." >&2
    exit 1
  fi

  domain=$(site_get "$site_file" DOMAIN)
  home=$(site_get "$site_file" WP_HOME)
  db_name=$(site_get "$site_file" DB_NAME)
  db_user=$(site_get "$site_file" DB_USER)
  ensure_site_secret "$site_file" DB_PASSWORD 32
  for key in "${WP_SECRET_KEYS[@]}"; do
    ensure_site_secret "$site_file" "$key" 64
  done
  ensure_spaces_vars "$site_file" "$site_id"
  db_pass=$(site_get "$site_file" DB_PASSWORD)
  db_prefix=$(site_get "$site_file" DB_PREFIX)
  if [ -z "$db_prefix" ]; then
    db_prefix=wp_
    upsert_file_var "$site_file" DB_PREFIX "$db_prefix"
  fi

  if [ -z "$domain" ] || [ -z "$home" ] || [ -z "$db_name" ] || [ -z "$db_user" ] || [ -z "$db_pass" ]; then
    echo "sites/${site_id}.env needs DOMAIN, WP_HOME, DB_NAME, DB_USER, and DB_PASSWORD." >&2
    exit 1
  fi
  if [[ ! "$db_name" =~ ^[A-Za-z0-9_]+$ ]] || [[ ! "$db_user" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "Site '${site_id}' has an unsafe database name or user." >&2
    exit 1
  fi
  case "$home" in
    http://*|https://*) ;;
    *)
      echo "Site '${site_id}' WP_HOME must start with http:// or https://." >&2
      exit 1
      ;;
  esac

  domain_key=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
  if [ -n "${SEEN_DOMAIN[$domain_key]:-}" ]; then
    echo "DOMAIN ${domain} is used by both '${SEEN_DOMAIN[$domain_key]}' and '${site_id}'." >&2
    exit 1
  fi
  if [ -n "${SEEN_DB[$db_name]:-}" ]; then
    echo "DB_NAME ${db_name} is used by both '${SEEN_DB[$db_name]}' and '${site_id}'." >&2
    exit 1
  fi
  if [ -n "${SEEN_USER[$db_user]:-}" ]; then
    echo "DB_USER ${db_user} is used by both '${SEEN_USER[$db_user]}' and '${site_id}'." >&2
    exit 1
  fi
  SEEN_DOMAIN[$domain_key]=$site_id
  SEEN_DB[$db_name]=$site_id
  SEEN_USER[$db_user]=$site_id

  weight=$(site_get "$site_file" ALLOCATION_WEIGHT)
  if [ -z "$weight" ]; then
    weight=1
  fi
  if [[ ! "$weight" =~ ^[1-9][0-9]*$ ]]; then
    echo "Site '${site_id}' ALLOCATION_WEIGHT must be a positive integer." >&2
    exit 1
  fi
  upsert_file_var "$site_file" ALLOCATION_WEIGHT "$weight"
  chmod 600 "$site_file"

  ssl_on=no
  if [ -f "certs/live/${domain}/fullchain.pem" ]; then
    ssl_on=yes
  fi

  SITE_IDS+=("$site_id")
  SITE_DOMAINS+=("$domain")
  SITE_HOMES+=("$home")
  SITE_DB_NAMES+=("$db_name")
  SITE_DB_USERS+=("$db_user")
  SITE_DB_PASSES+=("$db_pass")
  SITE_DB_PREFIXES+=("$db_prefix")
  SITE_WEIGHTS+=("$weight")
  SITE_CONTENTS+=("$(content_dir_for "$site_id")")
  SITE_SSL+=("$ssl_on")
done

declare -a SITE_MEM_MB=() SITE_CPU_MILLI=()
total_weight=0
for weight in "${SITE_WEIGHTS[@]}"; do
  total_weight=$((total_weight + weight))
done

capacity_problem() {
  if [ "$FORCE_SITES" = "yes" ]; then
    echo "Warning: $1 Continuing because FORCE_SITES=yes." >&2
  else
    echo "$1" >&2
    echo "Remove a site, lower an ALLOCATION_WEIGHT, or resize the server. For a benchmark, rerun with FORCE_SITES=yes." >&2
    exit 1
  fi
}

SITE_CAPACITY=$(site_capacity "$TOTAL_RAM_MB" $((CPU_CORES * 1000)))
if [ "$SITE_CAPACITY" -lt 1 ]; then
  capacity_problem "This host (${CPU_CORES} vCPU, ${TOTAL_RAM_MB}MB RAM) is below the 1 vCPU / 2 GB minimum for one site."
elif [ "$total_weight" -gt "$SITE_CAPACITY" ]; then
  capacity_problem "This host (${CPU_CORES} vCPU, ${TOTAL_RAM_MB}MB RAM) supports a total site weight of ${SITE_CAPACITY}, but the sites add up to ${total_weight}. The first site needs 1 vCPU and 2 GB; each extra weight-1 site needs 0.5 vCPU and 512MB."
fi

if [ "$AUTO_TUNE" = "yes" ]; then
  auto_size_services "$total_weight"
  set_env_var DB_MEM_LIMIT "${DB_MEM}m"
  set_env_var WP_MEM_LIMIT "${WP_MEM}m"
  set_env_var REDIS_MEM_LIMIT "${REDIS_MEM}m"
  set_env_var NGINX_MEM_LIMIT "${NGINX_MEM}m"
  set_env_var REDIS_MAXMEMORY "$REDIS_MAXMEMORY"
  set_env_var WP_CPU_MILLICORES "$WP_CPU_MILLICORES"
  INNODB_BUFFER_POOL_SIZE="${INNODB_BUFFER_POOL}M"
  INNODB_LOG_FILE_SIZE="${INNODB_LOG_FILE}M"
  set_env_var INNODB_BUFFER_POOL_SIZE "$INNODB_BUFFER_POOL_SIZE"
  set_env_var INNODB_LOG_FILE_SIZE "$INNODB_LOG_FILE_SIZE"
  DB_MEM_LIMIT="${DB_MEM}m"
  REDIS_MEM_LIMIT="${REDIS_MEM}m"
  NGINX_MEM_LIMIT="${NGINX_MEM}m"
  WP_MEM_LIMIT="${WP_MEM}m"
  total_wp_mb=$WP_MEM
fi

boost=0
max_weight=0
for index in "${!SITE_WEIGHTS[@]}"; do
  if [ "${SITE_WEIGHTS[$index]}" -gt "$max_weight" ]; then
    max_weight=${SITE_WEIGHTS[$index]}
    boost=$index
  fi
done

# Each site gets a weighted share of the WordPress RAM budget and of the host's CPU workers,
# whether or not Docker caps are applied.
worker_cap=$((WORKERS_PER_CPU * CPU_CORES))
site_floor_mb=$((OPCACHE_MB + FPM_MASTER_MB + MIN_SITE_WORKERS * PHP_WORKER_AVG_MB))
assigned_mb=0
assigned_cpu=0
for index in "${!SITE_IDS[@]}"; do
  site_mb=$((total_wp_mb * SITE_WEIGHTS[index] / total_weight))
  site_cpu=$((WP_CPU_MILLICORES * SITE_WEIGHTS[index] / total_weight))
  SITE_MEM_MB+=("$site_mb")
  SITE_CPU_MILLI+=("$site_cpu")
  assigned_mb=$((assigned_mb + site_mb))
  assigned_cpu=$((assigned_cpu + site_cpu))
done
SITE_MEM_MB[$boost]=$((SITE_MEM_MB[boost] + total_wp_mb - assigned_mb))
SITE_CPU_MILLI[$boost]=$((SITE_CPU_MILLI[boost] + WP_CPU_MILLICORES - assigned_cpu))

total_children=0
for index in "${!SITE_IDS[@]}"; do
  id=${SITE_IDS[$index]}
  share_mb=${SITE_MEM_MB[$index]}
  if [ "$share_mb" -lt "$site_floor_mb" ]; then
    capacity_problem "Site '${id}' gets ${share_mb}MB, below the ${site_floor_mb}MB needed for OPcache (${OPCACHE_MB}MB), the FPM master (${FPM_MASTER_MB}MB), and ${MIN_SITE_WORKERS} workers at PHP_WORKER_AVG_MB (${PHP_WORKER_AVG_MB}MB)."
  fi
  if [ "$ALLOCATE_RESOURCES" = "yes" ] && [ "${SITE_CPU_MILLI[$index]}" -lt 100 ]; then
    capacity_problem "Site '${id}' gets ${SITE_CPU_MILLI[$index]} millicores, below the 100 minimum for a Docker CPU cap."
  fi

  size_site_pool "$share_mb" $((worker_cap * SITE_WEIGHTS[index] / total_weight))
  total_children=$((total_children + PHP_CHILDREN))

  if [ "$ALLOCATE_RESOURCES" = "yes" ]; then
    if [ "$share_mb" -lt $((OPCACHE_MB + FPM_MASTER_MB + PHP_LIMIT_MB)) ]; then
      echo "Warning: site '${id}' has a ${share_mb}MB RAM cap; one request reaching PHP_MEMORY_LIMIT (${PHP_LIMIT_MB}MB) could be stopped by it." >&2
    fi
    site_mem_limit="${share_mb}m"
    site_cpu_limit=$(format_cpus "${SITE_CPU_MILLI[$index]}")
  else
    site_mem_limit=unlimited
    site_cpu_limit=unlimited
  fi

  SITE_MEMS+=("$site_mem_limit")
  SITE_CPUS+=("$site_cpu_limit")
  SITE_CHILDREN+=("$PHP_CHILDREN")
  SITE_STARTS+=("$START_SERVERS")
  SITE_MINS+=("$MIN_SPARE")
  SITE_MAXS+=("$MAX_SPARE")
  upsert_file_var "${site_files[$index]}" SITE_MEM_LIMIT "$site_mem_limit"
  upsert_file_var "${site_files[$index]}" SITE_CPU_LIMIT "$site_cpu_limit"
  upsert_file_var "${site_files[$index]}" PHP_FPM_PM_MAX_CHILDREN "$PHP_CHILDREN"
  upsert_file_var "${site_files[$index]}" PHP_FPM_PM_START_SERVERS "$START_SERVERS"
  upsert_file_var "${site_files[$index]}" PHP_FPM_PM_MIN_SPARE_SERVERS "$MIN_SPARE"
  upsert_file_var "${site_files[$index]}" PHP_FPM_PM_MAX_SPARE_SERVERS "$MAX_SPARE"
done

# Every worker holds one database connection.
needed_connections=$((total_children + 20))
if [ "$needed_connections" -lt 30 ]; then needed_connections=30; fi
if [ "$AUTO_TUNE" = "yes" ]; then
  MAX_CONNECTIONS=$needed_connections
  set_env_var MAX_CONNECTIONS "$MAX_CONNECTIONS"
elif [ "$MAX_CONNECTIONS" -lt $((total_children + 10)) ]; then
  echo "Warning: MAX_CONNECTIONS=${MAX_CONNECTIONS} is close to or below the ${total_children} PHP workers. Raise it to at least ${needed_connections}." >&2
fi

planned_mb=$((OS_RESERVE_MB + ${DB_MEM_LIMIT//[^0-9]/} + ${REDIS_MEM_LIMIT//[^0-9]/} + ${NGINX_MEM_LIMIT//[^0-9]/} + total_wp_mb))
if [ "$planned_mb" -gt "$TOTAL_RAM_MB" ]; then
  echo "Warning: planned memory is ${planned_mb}MB (OS ${OS_RESERVE_MB}MB + MariaDB ${DB_MEM_LIMIT} + Redis ${REDIS_MEM_LIMIT} + Nginx ${NGINX_MEM_LIMIT} + WordPress ${total_wp_mb}MB), more than the host's ${TOTAL_RAM_MB}MB. Lower WP_MEM_LIMIT or DB_MEM_LIMIT, or set AUTO_TUNE=yes." >&2
fi

umask 022
mkdir -p mysql mysql/init php php/pools nginx/conf.d nginx/logs backups
rm -rf mysql/sites

cat > nginx/conf.d/00-rate-limit.conf <<'EOF'
# Generated by generate-env.sh. Shared login rate limit for every vhost.
limit_req_zone $binary_remote_addr zone=wp_login:10m rate=10r/m;
limit_req_status 429;
EOF

for index in "${!SITE_IDS[@]}"; do
  content=${SITE_CONTENTS[$index]}
  mkdir -p "${content}"/{uploads,plugins,themes,upgrade,cache,mu-plugins,languages}
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "${PUID}:${PGID}" "$content"
  fi
done

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
max_input_time = ${FASTCGI_TIMEOUT}
max_input_vars = 5000

; OPcache
opcache.enable=1
opcache.memory_consumption=${OPCACHE_MEMORY_MB}
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=2

; Realpath cache
realpath_cache_size=4096K
realpath_cache_ttl=600
EOF

umask 077
rm -f mysql/init/*.sql
{
  echo "-- Generated by generate-env.sh. Each user can use only its own database."
  for index in "${!SITE_IDS[@]}"; do
    db_name=$(sql_escape "${SITE_DB_NAMES[$index]}")
    db_user=$(sql_escape "${SITE_DB_USERS[$index]}")
    db_pass=$(sql_escape "${SITE_DB_PASSES[$index]}")
    cat <<EOF
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${db_user}'@'%';
CREATE USER '${db_user}'@'%' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'%';
EOF
  done
  echo "FLUSH PRIVILEGES;"
} > mysql/init/sites.sql
chmod 600 mysql/init/sites.sql

{
  echo "# Generated by generate-env.sh. Do not edit."
  echo "services:"
  for index in "${!SITE_IDS[@]}"; do
    id=${SITE_IDS[$index]}
    limit_yaml=""
    secret_yaml=""
    if [ "$ALLOCATE_RESOURCES" = "yes" ]; then
      limit_yaml="    mem_limit: ${SITE_MEMS[$index]}
    cpus: \"${SITE_CPUS[$index]}\"
"
    fi
    for key in "${WP_SECRET_KEYS[@]}"; do
      secret_yaml+="      WORDPRESS_${key}: $(yaml_quote "$(site_get "${site_files[$index]}" "$key")")"$'\n'
    done
    cat <<EOF
  ${id}:
    image: \${PROJECT_NAME}-php:local
    build: .
    user: "\${PUID}:\${PGID}"
${limit_yaml}    container_name: \${PROJECT_NAME}_${id}
    restart: always
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_USER: $(yaml_quote "${SITE_DB_USERS[$index]}")
      WORDPRESS_DB_PASSWORD: $(yaml_quote "${SITE_DB_PASSES[$index]}")
      WORDPRESS_DB_NAME: $(yaml_quote "${SITE_DB_NAMES[$index]}")
      WORDPRESS_TABLE_PREFIX: $(yaml_quote "${SITE_DB_PREFIXES[$index]}")
${secret_yaml}      WORDPRESS_CONFIG_EXTRA: |
        define('WP_HOME', '$(php_sq "${SITE_HOMES[$index]}")');
        define('WP_SITEURL', '$(php_sq "${SITE_HOMES[$index]}")');
        define('DISALLOW_FILE_EDIT', true);
        define('WP_REDIS_HOST', 'redis');
        define('WP_REDIS_PORT', 6379);
        define('WP_REDIS_PASSWORD', '$(php_sq "${REDIS_PASSWORD}")');
        define('WP_REDIS_PREFIX', '${id}:');
        define('WP_REDIS_DATABASE', ${index});
        define('WP_REDIS_PLUGIN_PATH', '/opt/redis-cache');
        define('WP_REDIS_GRACEFUL', true);
        define('FS_METHOD', 'direct');
$(spaces_config_extra "${site_files[$index]}" "$id")
    volumes:
      - ./php/custom.ini:/usr/local/etc/php/conf.d/custom.ini:ro
      - ./php/pools/${id}.conf:/usr/local/etc/php-fpm.d/zz-pool.conf:ro
      - ${id}_html:/var/www/html
      - ./${SITE_CONTENTS[$index]}:/var/www/html/wp-content
    networks:
      - backend
EOF
  done

  echo "  nginx:"
  echo "    depends_on:"
  for id in "${SITE_IDS[@]}"; do
    echo "      ${id}:"
    echo "        condition: service_started"
  done
  echo "    volumes:"
  for index in "${!SITE_IDS[@]}"; do
    id=${SITE_IDS[$index]}
    echo "      - ${id}_html:/var/www/sites/${id}"
    echo "      - ./${SITE_CONTENTS[$index]}:/var/www/sites/${id}/wp-content"
  done

  echo "volumes:"
  for id in "${SITE_IDS[@]}"; do
    echo "  ${id}_html:"
  done
} > docker-compose.sites.yml
chmod 600 docker-compose.sites.yml
umask 022

for index in "${!SITE_IDS[@]}"; do
  id=${SITE_IDS[$index]}
  if [ "$PHP_FPM_PM" = "ondemand" ]; then
    cat > "php/pools/${id}.conf" <<EOF
; Generated by generate-env.sh for ${id}.
[www]
pm = ondemand
pm.max_children = ${SITE_CHILDREN[$index]}
pm.process_idle_timeout = 10s
pm.max_requests = 500
EOF
  else
    cat > "php/pools/${id}.conf" <<EOF
; Generated by generate-env.sh for ${id}.
[www]
pm = dynamic
pm.max_children = ${SITE_CHILDREN[$index]}
pm.start_servers = ${SITE_STARTS[$index]}
pm.min_spare_servers = ${SITE_MINS[$index]}
pm.max_spare_servers = ${SITE_MAXS[$index]}
pm.max_requests = 500
EOF
  fi

  listen_plain="listen 80;"
  if [ "$SITE_COUNT" -eq 1 ]; then
    listen_plain="listen 80 default_server;"
  fi

  {
    echo "# Generated by generate-env.sh."
    echo "server {"
    echo "    ${listen_plain}"
    echo "    server_name ${SITE_DOMAINS[$index]};"
    write_php_locations "$id"
    echo "}"
  } > "nginx/conf.d/${id}.conf"
done

# Replace the HTTP vhost when this site already has a certificate.
for index in "${!SITE_IDS[@]}"; do
  [ "${SITE_SSL[$index]}" = "yes" ] || continue
  id=${SITE_IDS[$index]}
  domain=${SITE_DOMAINS[$index]}
  listen_plain="listen 80;"
  listen_ssl="listen 443 ssl;"
  if [ "$SITE_COUNT" -eq 1 ]; then
    listen_plain="listen 80 default_server;"
    listen_ssl="listen 443 ssl default_server;"
  fi
  cat > "nginx/conf.d/${id}.conf" <<EOF
# Generated by generate-env.sh.
server {
    ${listen_plain}
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    ${listen_ssl}
    http2 on;
    server_name ${domain};

    ssl_certificate     /etc/nginx/certs/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/live/${domain}/privkey.pem;
    ssl_trusted_certificate /etc/nginx/certs/live/${domain}/chain.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    add_header Strict-Transport-Security "max-age=31536000" always;

    resolver 127.0.0.11 valid=10s ipv6=off;
    root /var/www/sites/${id};
    index index.php;
    client_max_body_size ${UPLOAD_MAX};

$(write_security_headers)
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /wp-login.php {
        limit_req zone=wp_login burst=5 nodelay;
$(write_security_headers)
$(write_fastcgi_php "$id" "        fastcgi_param HTTPS on;
        fastcgi_param HTTP_X_FORWARDED_PROTO https;")
    }

    location ~ \.php\$ {
$(write_security_headers)
$(write_fastcgi_php "$id" "        fastcgi_param HTTPS on;
        fastcgi_param HTTP_X_FORWARDED_PROTO https;")
    }

    location = /xmlrpc.php { deny all; }
    location = /wp-config.php { deny all; }
    location ~ /\.ht { deny all; }

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        allow all;
    }

    access_log /var/log/nginx/${id}.access.log;
    error_log /var/log/nginx/${id}.error.log;
}
EOF
done

any_ssl=no
for flag in "${SITE_SSL[@]}"; do
  if [ "$flag" = "yes" ]; then
    any_ssl=yes
    break
  fi
done

if [ "$SITE_COUNT" -gt 1 ]; then
  cat > nginx/conf.d/00-default.conf <<'EOF'
# Unknown hostnames are closed. Named sites keep their own server blocks.
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
EOF
  if [ "$any_ssl" = "yes" ]; then
    cat >> nginx/conf.d/00-default.conf <<'EOF'

server {
    listen 443 ssl default_server;
    http2 on;
    server_name _;
    ssl_reject_handshake on;
}
EOF
  fi
else
  rm -f nginx/conf.d/00-default.conf
fi

for conf in nginx/conf.d/*.conf; do
  base=$(basename "$conf" .conf)
  [ "$base" = "00-default" ] && continue
  [ "$base" = "00-rate-limit" ] && continue
  known=no
  for id in "${SITE_IDS[@]}"; do
    if [ "$id" = "$base" ]; then
      known=yes
      break
    fi
  done
  if [ "$known" = "no" ]; then
    rm -f "$conf"
  fi
done

for pool in php/pools/*.conf; do
  base=$(basename "$pool" .conf)
  known=no
  for id in "${SITE_IDS[@]}"; do
    if [ "$id" = "$base" ]; then
      known=yes
      break
    fi
  done
  if [ "$known" = "no" ]; then
    rm -f "$pool"
  fi
done
rm -f php/zz-pool.conf nginx/conf.d/ssl.conf nginx/conf.d/http-redirect.conf

chmod 644 mysql/my.cnf php/custom.ini php/pools/*.conf nginx/conf.d/*.conf

compose_file="docker-compose.yml:docker-compose.sites.yml"
if [ "$any_ssl" = "yes" ]; then
  compose_file="${compose_file}:docker-compose.ssl.yml"
fi
set_env_var COMPOSE_FILE "$compose_file"

echo "Host: ${CPU_CORES} vCPU, ${TOTAL_RAM_MB}MB RAM. Capacity: total site weight ${SITE_CAPACITY}; in use: ${total_weight}."
echo "Services: MariaDB ${DB_MEM_LIMIT} (buffer pool ${INNODB_BUFFER_POOL_SIZE}, ${MAX_CONNECTIONS} connections), Redis ${REDIS_MEM_LIMIT}, WordPress budget ${total_wp_mb}MB. AUTO_TUNE=${AUTO_TUNE}."
echo "PHP: memory_limit ${PHP_MEMORY_LIMIT}, OPcache ${OPCACHE_MB}MB, ${PHP_WORKER_AVG_MB}MB average worker, pm=${PHP_FPM_PM}."
if [ "$ALLOCATE_RESOURCES" = "yes" ]; then
  echo "Configured ${SITE_COUNT} site(s) with Docker CPU and RAM caps:"
  for index in "${!SITE_IDS[@]}"; do
    echo "  ${SITE_IDS[$index]}: ${SITE_CHILDREN[$index]} workers, ${SITE_MEMS[$index]} RAM, ${SITE_CPUS[$index]} CPUs (weight ${SITE_WEIGHTS[$index]})"
  done
else
  echo "Configured ${SITE_COUNT} site(s) with no Docker CPU or RAM caps:"
  for index in "${!SITE_IDS[@]}"; do
    echo "  ${SITE_IDS[$index]}: ${SITE_CHILDREN[$index]} workers, ${SITE_MEM_MB[$index]}MB sizing share (weight ${SITE_WEIGHTS[$index]})"
  done
fi

./provision-sites.sh
./cron-setup.sh
