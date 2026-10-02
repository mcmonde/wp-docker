#!/bin/sh
# Install the Redis Object Cache drop-in onto the wp-content mount, then
# start the official WordPress entrypoint. The plugin itself lives in
# /opt/redis-cache so the wp-content bind mount does not hide it.
set -eu

src=/opt/redis-cache/includes/object-cache.php
dst=/var/www/html/wp-content/object-cache.php

if [ -f "$src" ]; then
  mkdir -p /var/www/html/wp-content 2>/dev/null || true
  if [ ! -e "$dst" ] || [ "$src" -nt "$dst" ]; then
    if ! cp "$src" "$dst"; then
      echo "wp-stack: could not install ${dst}. Redis object cache stays off until that file is writable by the container user." >&2
    fi
  fi
fi

spaces_loader=/opt/do-spaces-uploads/loader.php
spaces_dst=/var/www/html/wp-content/mu-plugins/do-spaces-uploads.php
if [ -f "$spaces_loader" ]; then
  mkdir -p /var/www/html/wp-content/mu-plugins 2>/dev/null || true
  if [ ! -e "$spaces_dst" ] || [ "$spaces_loader" -nt "$spaces_dst" ]; then
    if ! cp "$spaces_loader" "$spaces_dst"; then
      echo "wp-stack: could not install ${spaces_dst}. DO Spaces uploads stay off until that file is writable." >&2
    fi
  fi
fi

exec docker-entrypoint.sh "$@"
