# WordPress Docker Stack

Single-host WordPress stack sized from the machine's RAM and CPU when you generate `.env`. It runs PHP-FPM, Nginx, MariaDB, and Redis.

## Requirements

- Docker Compose v2
- Linux
- About 2 GB RAM (4 GB or more is comfortable)

## Setup

Generate configuration. This writes `.env` only when it is missing, with random database passwords, and refreshes MariaDB, PHP, PHP-FPM, and Nginx config from those values:

```bash
./generate-env.sh
```

Edit `.env` before you point a real site at the stack:

- `DOMAIN` is the bare hostname (`example.com`). `localhost` is for HTTP on this machine.
- `WP_HOME` is the full site URL (`http://localhost` or `https://example.com`).
- `EMAIL` is the Let's Encrypt contact. Leave the placeholder until you enable HTTPS.
- `PUID` and `PGID` should be the user that owns `wp-content`.

Start the stack. The first start builds the WordPress image, which installs WP-CLI and the Redis Object Cache plugin:

```bash
docker compose up -d
```

The site is served on port 80. phpMyAdmin is not started. To open it on `127.0.0.1:8080` only:

```bash
docker compose --profile tools up -d
```

From another machine, reach it through an SSH tunnel to that address. Log in with `MYSQL_USER` and `MYSQL_PASSWORD` from `.env`.

Re-running `./generate-env.sh` rewrites the derived config files and does not rotate passwords.

## HTTPS

When this host is the public edge and DNS for `DOMAIN` points here, set `WP_HOME` to `https://example.com`, set `EMAIL`, and run:

```bash
./enable-ssl.sh
```

That script requests a certificate over HTTP-01, then publishes port 443 and redirects port 80. Renewal runs daily at 04:15 through `renew-ssl.sh`.

If Cloudflare or another proxy already terminates TLS, keep this stack on HTTP and do not run `enable-ssl.sh`.

## URL changes

```bash
./change-url.sh https://old.example https://new.example
```

This runs `wp search-replace` as the `PUID` user, updates Elementor when that plugin is installed, flushes rewrite rules, and clears Redis.

## What is tuned

| Piece | Where it lives |
|---|---|
| MariaDB buffer pool and connections | `mysql/my.cnf` |
| PHP memory, uploads, OPcache | `php/custom.ini` |
| PHP-FPM workers | `php/zz-pool.conf` |
| Nginx body size and FastCGI timeout | `nginx/conf.d/default.conf` |
| Redis eviction cap | `REDIS_MAXMEMORY` in `.env` (about 75% of the container limit) |

PHP-FPM workers are sized from the WordPress container limit after reserving OPcache and a small overhead, using about 80 MB per worker, capped at 32. `memory_limit` stays a per-request ceiling.

Redis object caching is on when the container can write `wp-content/object-cache.php`. The drop-in is copied from the image on start. `WP_REDIS_GRACEFUL` keeps the site on the database if Redis is down.

## Backups

`generate-env.sh` installs a daily 03:00 cron that runs `backup.sh`. Dumps are kept in `backups/` for 30 days. Restore with `./restore.sh`.

## Layout

- `docker-compose.yml` is the HTTP stack. phpMyAdmin is the `tools` profile. Certbot is the `ssl` profile.
- `docker-compose.ssl.yml` publishes port 443. `enable-ssl.sh` applies it after a certificate exists.
- `up.sh` and `down.sh` start and stop the default HTTP stack.
