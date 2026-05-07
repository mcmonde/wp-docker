#!/bin/bash

set -e

echo "Detecting system resources..."

# -----------------------------
# Base system info
# -----------------------------
TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
CPU_CORES=$(nproc)

echo "Detected RAM: ${TOTAL_RAM_MB}MB"
echo "Detected CPU: ${CPU_CORES} cores"

# -----------------------------
# Reserve system resources
# -----------------------------
# Keep 20% RAM for OS + Docker engine safety
SAFE_RAM_MB=$((TOTAL_RAM_MB * 80 / 100))

echo "Usable RAM after reservation: ${SAFE_RAM_MB}MB"

# -----------------------------
# Application allocation strategy
# -----------------------------
DB_MEM=$((SAFE_RAM_MB * 35 / 100))
WP_MEM=$((SAFE_RAM_MB * 45 / 100))
REDIS_MEM=$((SAFE_RAM_MB * 10 / 100))

# -----------------------------
# MariaDB tuning
# -----------------------------
INNODB_BUFFER_POOL=$((DB_MEM * 70 / 100))

INNODB_LOG_FILE=$((DB_MEM * 10 / 100))
if [ $INNODB_LOG_FILE -lt 128 ]; then INNODB_LOG_FILE=128; fi
if [ $INNODB_LOG_FILE -gt 512 ]; then INNODB_LOG_FILE=512; fi

MAX_CONNECTIONS=$((CPU_CORES * 20))
if [ $MAX_CONNECTIONS -lt 50 ]; then MAX_CONNECTIONS=50; fi
if [ $MAX_CONNECTIONS -gt 200 ]; then MAX_CONNECTIONS=200; fi

if [ "$INNODB_BUFFER_POOL" -lt 256 ]; then
  echo "❌ Unsafe DB config detected: INNODB_BUFFER_POOL=${INNODB_BUFFER_POOL}MB"
  echo "👉 Increase server RAM or adjust allocation ratios"
  exit 1
fi

# DB safety
if [ "$DB_MEM" -lt 512 ]; then
  echo "❌ DB memory too low"
  exit 1
fi

# Redis safety
if [ "$REDIS_MEM" -lt 128 ]; then
  echo "❌ Redis memory too low"
  exit 1
fi

# -----------------------------
# PHP-FPM tuning
# -----------------------------
PHP_CHILDREN=$((WP_MEM / 120))

if [ $PHP_CHILDREN -lt 4 ]; then PHP_CHILDREN=4; fi
if [ $PHP_CHILDREN -gt 32 ]; then PHP_CHILDREN=32; fi

START_SERVERS=$((PHP_CHILDREN / 4))
MIN_SPARE=$((PHP_CHILDREN / 8))
MAX_SPARE=$((PHP_CHILDREN / 2))

# -----------------------------
# PHP MEMORY LIMIT tuning
# -----------------------------
PHP_MEMORY_LIMIT=$((WP_MEM / 4))

if [ $PHP_MEMORY_LIMIT -lt 256 ]; then
  PHP_MEMORY_LIMIT=256
fi

if [ $PHP_MEMORY_LIMIT -gt 1024 ]; then
  PHP_MEMORY_LIMIT=1024
fi

# -----------------------------
# Generate env file
# -----------------------------
cat > .env <<EOF
PUID=1000
PGID=1000

PROJECT_NAME=wordpress

DOMAIN=http://localhost
EMAIL=your_email@here.com
DB_PREFIX=wp_

# Database Secrets
MYSQL_ROOT_PASSWORD=root
MYSQL_DATABASE=wordpress
MYSQL_USER=default
MYSQL_PASSWORD=secret

# -----------------------------
# Docker Memory Limits
# -----------------------------
DB_MEM_LIMIT=${DB_MEM}m
WP_MEM_LIMIT=${WP_MEM}m
REDIS_MEM_LIMIT=${REDIS_MEM}m

# -----------------------------
# MariaDB Dynamic Tuning
# -----------------------------
INNODB_BUFFER_POOL_SIZE=${INNODB_BUFFER_POOL}M
INNODB_LOG_FILE_SIZE=${INNODB_LOG_FILE}M
MAX_CONNECTIONS=${MAX_CONNECTIONS}

# -----------------------------
# PHP-FPM Tuning
# -----------------------------
PHP_FPM_PM_MAX_CHILDREN=${PHP_CHILDREN}
PHP_FPM_PM_START_SERVERS=${START_SERVERS}
PHP_FPM_PM_MIN_SPARE_SERVERS=${MIN_SPARE}
PHP_FPM_PM_MAX_SPARE_SERVERS=${MAX_SPARE}

# -----------------------------
# System Info (optional debugging)
# -----------------------------
TOTAL_RAM_MB=${TOTAL_RAM_MB}
SAFE_RAM_MB=${SAFE_RAM_MB}
CPU_CORES=${CPU_CORES}

EOF

echo "✅ .env created successfully"

cat > mysql/my.cnf <<EOF
[mysqld]

innodb_buffer_pool_size = ${INNODB_BUFFER_POOL}M
innodb_log_file_size = ${INNODB_LOG_FILE}M

max_connections = ${MAX_CONNECTIONS}

innodb_flush_log_at_trx_commit = 2
innodb_file_per_table = 1
EOF

echo "✅ my.cnf created successfully at mysql/my.cnf"

cat > php/custom.ini <<EOF
memory_limit = ${PHP_MEMORY_LIMIT}M
upload_max_filesize = 128M
post_max_size = 128M
max_execution_time = 300
max_input_vars = 5000

; OPcache
opcache.enable=1
opcache.memory_consumption=256
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=2

; Realpath cache
realpath_cache_size=256K
realpath_cache_ttl=600
EOF

echo "✅ custom.ini created successfully at php/custom.ini"

mkdir -p wp-content/{uploads,plugins,themes,upgrade,cache,mu-plugins,languages,backups}

# generate cron
./cron-setup.sh