#!/bin/bash
# Detect host RAM and CPU, write stack .env once, and refresh one
# PHP container and Nginx vhost per site. One MariaDB holds every site
# database. Re-running does not rotate passwords or WordPress keys.

set -euo pipefail

cd "$(dirname "$0")"
shopt -s nullglob

FPM_OVERHEAD_MB=64
UPLOAD_DEFAULT=128M
FASTCGI_DEFAULT=300
PHP_MEMORY_DEFAULT=256M
OPCACHE_DEFAULT=256

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

compute_pool() {
  local wp_mb=$1
  local site_label=$2
  local opcache_mb
  local php_limit_mb
  local available
  local min_needed
  opcache_mb=$(memory_limit_mb "${OPCACHE_MEMORY_MB:-$OPCACHE_DEFAULT}")
  php_limit_mb=$(memory_limit_mb "${PHP_MEMORY_LIMIT:-$PHP_MEMORY_DEFAULT}")
  available=$((wp_mb - opcache_mb - FPM_OVERHEAD_MB))
  min_needed=$((php_limit_mb * 2))

  if [ "$available" -lt "$min_needed" ]; then
    echo "Site '${site_label}' is assigned ${wp_mb}MB." >&2
    echo "That cannot fit OPcache (${opcache_mb}MB), ${FPM_OVERHEAD_MB}MB overhead, and 2 workers at PHP memory_limit (${php_limit_mb}MB)." >&2
    echo "Lower its ALLOCATION_WEIGHT, remove a site, lower PHP_MEMORY_LIMIT or OPCACHE_MEMORY_MB, or raise WP_MEM_LIMIT." >&2
    exit 1
  fi

  PHP_CHILDREN=$((available / php_limit_mb))
  if [ "$PHP_CHILDREN" -gt 32 ]; then
    PHP_CHILDREN=32
  fi

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

  if [ -z "$key" ] || [ -z "$secret" ] || [ -z "$bucket" ] || [ -z "$region" ]; then
    echo "Site '${id}' has SPACES_ENABLED=yes but needs SPACES_KEY, SPACES_SECRET, SPACES_BUCKET, and SPACES_REGION." >&2
    exit 1
  fi

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
      echo "Running as root on a root-owned tree. Defaulting PUID/PGID to 1000."
    fi
  fi

  REDIS_MAXMEMORY="$((REDIS_MEM * 75 / 100))mb"
  MYSQL_ROOT_PASSWORD=$(rand_secret)
  REDIS_PASSWORD=$(rand_secret)
  WP_CPU_MILLICORES=$((CPU_CORES * 800))
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

# Docker memory limits for MariaDB, Redis, and Nginx.
# WP_MEM_LIMIT and WP_CPU_MILLICORES are the WordPress budget.
# ALLOCATE_RESOURCES=yes splits that budget across sites.
# ALLOCATE_RESOURCES=no omits CPU and RAM limits on WordPress containers.
DB_MEM_LIMIT=${DB_MEM}m
WP_MEM_LIMIT=${WP_MEM}m
REDIS_MEM_LIMIT=${REDIS_MEM}m
NGINX_MEM_LIMIT=256m
REDIS_MAXMEMORY=${REDIS_MAXMEMORY}
ALLOCATE_RESOURCES=${ALLOCATE_RESOURCES}
WP_CPU_MILLICORES=${WP_CPU_MILLICORES}

INNODB_BUFFER_POOL_SIZE=${INNODB_BUFFER_POOL}M
INNODB_LOG_FILE_SIZE=${INNODB_LOG_FILE}M
MAX_CONNECTIONS=${MAX_CONNECTIONS}

PHP_MEMORY_LIMIT=${PHP_MEMORY_DEFAULT}
UPLOAD_MAX=${UPLOAD_DEFAULT}
FASTCGI_TIMEOUT=${FASTCGI_DEFAULT}
OPCACHE_MEMORY_MB=${OPCACHE_DEFAULT}

TOTAL_RAM_MB=${TOTAL_RAM_MB}
SAFE_RAM_MB=${SAFE_RAM_MB}
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

boost=0
max_weight=0
for index in "${!SITE_WEIGHTS[@]}"; do
  if [ "${SITE_WEIGHTS[$index]}" -gt "$max_weight" ]; then
    max_weight=${SITE_WEIGHTS[$index]}
    boost=$index
  fi
done

if [ "$ALLOCATE_RESOURCES" = "yes" ]; then
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

  for index in "${!SITE_IDS[@]}"; do
    if [ "${SITE_MEM_MB[$index]}" -lt 1 ] || [ "${SITE_CPU_MILLI[$index]}" -lt 100 ]; then
      echo "Site '${SITE_IDS[$index]}' received ${SITE_MEM_MB[$index]}MB and ${SITE_CPU_MILLI[$index]} millicores." >&2
      echo "Lower another site's ALLOCATION_WEIGHT or raise WP_MEM_LIMIT and WP_CPU_MILLICORES." >&2
      exit 1
    fi
    compute_pool "${SITE_MEM_MB[$index]}" "${SITE_IDS[$index]}"
    SITE_MEMS+=("${SITE_MEM_MB[$index]}m")
    SITE_CPUS+=("$(format_cpus "${SITE_CPU_MILLI[$index]}")")
    SITE_CHILDREN+=("$PHP_CHILDREN")
    SITE_STARTS+=("$START_SERVERS")
    SITE_MINS+=("$MIN_SPARE")
    SITE_MAXS+=("$MAX_SPARE")
    upsert_file_var "${site_files[$index]}" SITE_MEM_LIMIT "${SITE_MEM_MB[$index]}m"
    upsert_file_var "${site_files[$index]}" SITE_CPU_LIMIT "$(format_cpus "${SITE_CPU_MILLI[$index]}")"
    upsert_file_var "${site_files[$index]}" PHP_FPM_PM_MAX_CHILDREN "$PHP_CHILDREN"
    upsert_file_var "${site_files[$index]}" PHP_FPM_PM_START_SERVERS "$START_SERVERS"
    upsert_file_var "${site_files[$index]}" PHP_FPM_PM_MIN_SPARE_SERVERS "$MIN_SPARE"
    upsert_file_var "${site_files[$index]}" PHP_FPM_PM_MAX_SPARE_SERVERS "$MAX_SPARE"
  done
else
  if [ "$SITE_COUNT" -gt 0 ]; then
    pool_mb=$((total_wp_mb / SITE_COUNT))
  else
    pool_mb=$total_wp_mb
  fi
  if [ "$pool_mb" -lt 1 ]; then
    pool_mb=1
  fi
  for index in "${!SITE_IDS[@]}"; do
    compute_pool "$pool_mb" "${SITE_IDS[$index]}"
    SITE_MEMS+=("unlimited")
    SITE_CPUS+=("unlimited")
    SITE_CHILDREN+=("$PHP_CHILDREN")
    SITE_STARTS+=("$START_SERVERS")
    SITE_MINS+=("$MIN_SPARE")
    SITE_MAXS+=("$MAX_SPARE")
    upsert_file_var "${site_files[$index]}" SITE_MEM_LIMIT unlimited
    upsert_file_var "${site_files[$index]}" SITE_CPU_LIMIT unlimited
    upsert_file_var "${site_files[$index]}" PHP_FPM_PM_MAX_CHILDREN "$PHP_CHILDREN"
    upsert_file_var "${site_files[$index]}" PHP_FPM_PM_START_SERVERS "$START_SERVERS"
    upsert_file_var "${site_files[$index]}" PHP_FPM_PM_MIN_SPARE_SERVERS "$MIN_SPARE"
    upsert_file_var "${site_files[$index]}" PHP_FPM_PM_MAX_SPARE_SERVERS "$MAX_SPARE"
  done
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

if [ "$ALLOCATE_RESOURCES" = "yes" ]; then
  echo "Configured ${SITE_COUNT} site(s) with CPU and RAM allocation:"
  for index in "${!SITE_IDS[@]}"; do
    echo "  ${SITE_IDS[$index]}: ${SITE_MEMS[$index]} RAM, ${SITE_CPUS[$index]} CPUs (weight ${SITE_WEIGHTS[$index]})"
  done
else
  echo "Configured ${SITE_COUNT} site(s) with no CPU or RAM limits on WordPress."
fi

./provision-sites.sh
./cron-setup.sh
