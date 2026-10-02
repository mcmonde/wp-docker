# Usage guide

This document explains how to run and configure the multi-instance WordPress Docker stack: environment files, WordPress configuration, adding sites, and day-to-day operations.

For a short overview, see [README.md](../README.md). For production deployment, see [PRODUCTION.md](PRODUCTION.md). To store uploads in DigitalOcean Spaces, see [SPACES.md](SPACES.md).

---

## How the stack is organized

| Layer | Shared or per instance |
|---|---|
| Nginx, MariaDB, Redis | Shared |
| PHP-FPM container | One per instance |
| Database + DB user | One per instance (same MariaDB server) |
| `sites/<id>/wp-content/` | One per instance |
| `sites/<id>.env` | One per instance |
| Nginx vhost `nginx/conf.d/<id>.conf` | One per instance (generated) |

WordPress core files live in a Docker volume per instance (`<id>_html`). Themes, plugins, and uploads live on the host under `sites/<id>/wp-content/`.

---

## Configuration files

| File | Purpose | Git |
|---|---|---|
| `.env` | Stack-wide settings (MariaDB root, RAM/CPU budget, PHP tuning) | Ignored |
| `sites/<id>.env` | One instance: domain, URL, database, table prefix, secrets | Ignored |
| `docker-compose.sites.yml` | Generated PHP services | Ignored |
| `mysql/init/sites.sql` | Generated DB/user grants | Ignored |
| `nginx/conf.d/<id>.conf` | Generated vhosts | Ignored |
| `php/pools/<id>.conf` | Generated FPM pools | Ignored |

**Rule of thumb:** edit `.env` or `sites/<id>.env`, then regenerate. Do not hand-edit generated files—they are overwritten by `./generate-env.sh`.

---

## First-time setup

```bash
./generate-env.sh    # creates .env and sites/default.env
# Edit .env: EMAIL, PUID, PGID if needed
# Edit sites/default.env: DOMAIN, WP_HOME
./up.sh              # builds image, starts stack, creates databases
```

Open the site in a browser and complete the WordPress install wizard.

---

## Stack variables (`.env`)

Created on the first `./generate-env.sh` run. Re-running **does not rotate** existing passwords or keys unless they are still placeholders (`change-me`, empty, or too short).

### Identity and contact

| Variable | Description | When to change |
|---|---|---|
| `PUID` | Linux user ID files are owned as inside containers | When host user differs from generated value |
| `PGID` | Linux group ID | Same as `PUID` |
| `PROJECT_NAME` | Docker container name prefix (default `wordpress`) | Rarely |
| `EMAIL` | Let's Encrypt contact address | Before `./enable-ssl.sh` |
| `COMPOSE_FILE` | Compose file list (auto-set) | Do not edit manually; updated when SSL certs exist |

### Secrets

| Variable | Description |
|---|---|
| `MYSQL_ROOT_PASSWORD` | MariaDB root; used by backups and `./provision-sites.sh` |
| `REDIS_PASSWORD` | Redis `requirepass`; passed to WordPress as `WP_REDIS_PASSWORD` |

Site database passwords live in `sites/<id>.env`, not in `.env`.

### Resource allocation

| Variable | Description | Default behaviour |
|---|---|---|
| `ALLOCATE_RESOURCES` | `yes` = Docker `mem_limit`/`cpus` on each PHP container; `no` = no cap on PHP containers | Asked on first run |
| `WP_MEM_LIMIT` | Total WordPress RAM budget (MB) | ~45% of 80% of host RAM |
| `WP_CPU_MILLICORES` | Total WordPress CPU budget (`1000` = 1 core) | ~80% of host cores × 1000 |
| `DB_MEM_LIMIT` | MariaDB container RAM cap | ~35% of safe RAM |
| `REDIS_MEM_LIMIT` | Redis container RAM cap | ~10% of safe RAM |
| `NGINX_MEM_LIMIT` | Nginx container RAM cap | `256m` |
| `REDIS_MAXMEMORY` | Redis `maxmemory` setting | 75% of `REDIS_MEM_LIMIT` |

### MariaDB tuning (written to `mysql/my.cnf`)

| Variable | Description |
|---|---|
| `INNODB_BUFFER_POOL_SIZE` | InnoDB buffer pool (~70% of `DB_MEM_LIMIT`) |
| `INNODB_LOG_FILE_SIZE` | InnoDB log size |
| `MAX_CONNECTIONS` | Max MariaDB connections |

### PHP / Nginx tuning (written to `php/custom.ini` and nginx)

| Variable | Description | Default |
|---|---|---|
| `PHP_MEMORY_LIMIT` | PHP `memory_limit` per request | `256M` |
| `UPLOAD_MAX` | Upload size (`upload_max_filesize`, `post_max_size`, nginx `client_max_body_size`) | `128M` |
| `FASTCGI_TIMEOUT` | PHP `max_execution_time`, nginx FastCGI timeouts | `300` |
| `OPCACHE_MEMORY_MB` | OPcache size in `php/custom.ini` | `256` |

### Informational (read-only hints)

| Variable | Description |
|---|---|
| `TOTAL_RAM_MB` | Host RAM detected at setup |
| `SAFE_RAM_MB` | 80% of host RAM |
| `CPU_CORES` | Host CPU count detected at setup |

### Changing stack variables

1. Edit `.env`.
2. Run `./generate-env.sh` (refreshes `mysql/my.cnf`, `php/custom.ini`, pools, nginx, compose).
3. Run `./up.sh` (recreates containers if limits changed).

Example — raise upload limit:

```bash
# In .env
UPLOAD_MAX=256M

./generate-env.sh
./up.sh
```

---

## Per-instance variables (`sites/<id>.env`)

Each instance has its own file, e.g. `sites/default.env`, `sites/blog.env`. See also [sites/example.env.sample](../sites/example.env.sample).

### Required (you set or `./add-site.sh` sets)

| Variable | Description | Example |
|---|---|---|
| `DOMAIN` | Hostname Nginx matches (no scheme) | `blog.example.com` |
| `WP_HOME` | Full site URL with `http://` or `https://` | `https://blog.example.com` |
| `DB_NAME` | MariaDB database name | `blog` |
| `DB_USER` | MariaDB user (scoped to `DB_NAME` only) | `blog` |
| `DB_PASSWORD` | MariaDB password | Auto-generated |
| `DB_PREFIX` | WordPress table prefix (must end with `_`) | `wp_` |
| `ALLOCATION_WEIGHT` | Share of WordPress RAM/CPU when `ALLOCATE_RESOURCES=yes` | `1` |

### Auto-generated secrets (do not commit)

| Variable | Description |
|---|---|
| `AUTH_KEY`, `SECURE_AUTH_KEY`, `LOGGED_IN_KEY`, `NONCE_KEY` | WordPress auth keys |
| `AUTH_SALT`, `SECURE_AUTH_SALT`, `LOGGED_IN_SALT`, `NONCE_SALT` | WordPress salts |

Generated on first `./generate-env.sh` if missing or placeholder. Rotating them logs everyone out.

### Auto-generated tuning (written by `./generate-env.sh`)

| Variable | Description |
|---|---|
| `SITE_MEM_LIMIT` | This instance's Docker RAM cap |
| `SITE_CPU_LIMIT` | This instance's Docker CPU cap |
| `PHP_FPM_PM_MAX_CHILDREN` | FPM worker count |
| `PHP_FPM_PM_START_SERVERS` | FPM start servers |
| `PHP_FPM_PM_MIN_SPARE_SERVERS` | FPM min spare |
| `PHP_FPM_PM_MAX_SPARE_SERVERS` | FPM max spare |

You normally leave the FPM keys alone; they are recalculated when site count or weights change.

### Spaces (optional, disabled by default)

Every `sites/<id>.env` includes DigitalOcean Spaces keys with **`SPACES_ENABLED=no`**. You do not add them manually.

| When | What happens |
|---|---|
| First `./generate-env.sh` | `sites/default.env` is created and gets the Spaces block |
| `./add-site.sh` | The new site file gets the same block (via `./generate-env.sh`) |
| Later `./generate-env.sh` runs | Missing `SPACES_*` keys are added. Empty keys are filled only while Spaces is disabled; enabled sites are never rewritten. |

Defaults:

```bash
SPACES_ENABLED=no
SPACES_KEY=your-key-do-space-here
SPACES_SECRET=your-secret-do-space-here
SPACES_BUCKET=bucket-name-here
SPACES_REGION=sgp1
SPACES_ENDPOINT=https://SPACES_BUCKET.SPACES_REGION.digitaloceanspaces.com
SPACES_PUBLIC_URL=https://SPACES_BUCKET.SPACES_REGION.cdn.digitaloceanspaces.com
SPACES_PREFIX=<id>
SPACES_PATH_STYLE=no
```

`SPACES_BUCKET` and `SPACES_REGION` inside the URLs are replaced with your bucket and region values. `SPACES_PREFIX` is the folder inside the bucket and defaults to the site id. Leave `SPACES_PATH_STYLE=no` for DigitalOcean.

To enable Spaces: set `SPACES_ENABLED=yes`, replace the key, secret, and bucket placeholders, then run `./generate-env.sh`, `docker compose build`, and `./up.sh`. `./generate-env.sh` refuses to continue if placeholders remain on an enabled site. Full guide: [SPACES.md](SPACES.md).

---

## WordPress configuration (`wp-config.php`)

You **do not edit** `wp-config.php` inside the container. The official WordPress image builds it from environment variables. This stack sets those variables in the generated `docker-compose.sites.yml`.

### Database (from `sites/<id>.env`)

| Compose env var | Source |
|---|---|
| `WORDPRESS_DB_HOST` | Always `db` |
| `WORDPRESS_DB_NAME` | `DB_NAME` |
| `WORDPRESS_DB_USER` | `DB_USER` |
| `WORDPRESS_DB_PASSWORD` | `DB_PASSWORD` |
| `WORDPRESS_TABLE_PREFIX` | `DB_PREFIX` |

### Security keys (from `sites/<id>.env`)

Mapped as `WORDPRESS_AUTH_KEY`, `WORDPRESS_SECURE_AUTH_KEY`, `WORDPRESS_LOGGED_IN_KEY`, `WORDPRESS_NONCE_KEY`, and the four `*_SALT` variants.

### Extra defines (`WORDPRESS_CONFIG_EXTRA`)

Regenerated on every `./generate-env.sh`. Current defaults:

```php
define('WP_HOME', '<WP_HOME from sites env>');
define('WP_SITEURL', '<WP_HOME from sites env>');
define('DISALLOW_FILE_EDIT', true);
define('WP_REDIS_HOST', 'redis');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_PASSWORD', '<from .env REDIS_PASSWORD>');
define('WP_REDIS_PREFIX', '<id>:');
define('WP_REDIS_DATABASE', <index>);
define('WP_REDIS_PLUGIN_PATH', '/opt/redis-cache');
define('WP_REDIS_GRACEFUL', true);
define('FS_METHOD', 'direct');
define('DO_SPACES_ENABLED', false);   // true when SPACES_ENABLED=yes in sites/<id>.env
```

When `SPACES_ENABLED=yes` in `sites/<id>.env`, `generate-env.sh` also injects `DO_SPACES_KEY`, `DO_SPACES_SECRET`, `DO_SPACES_BUCKET`, and related defines. See [SPACES.md](SPACES.md).

To add custom defines (e.g. `WP_DEBUG`), extend the `WORDPRESS_CONFIG_EXTRA` block in `generate-env.sh`, then run `./generate-env.sh` and `./up.sh`. Per-site extras are not supported out of the box.

### Official image variables you can add manually

The [WordPress Docker image](https://hub.docker.com/_/wordpress) also supports e.g. `WORDPRESS_DEBUG=1`. Anything added directly to `docker-compose.sites.yml` is lost on the next `./generate-env.sh`—add it in `generate-env.sh` instead.

### Applying config changes

```bash
# Edit sites/<id>.env (or extend generate-env.sh for extra defines)
./generate-env.sh
./up.sh
```

PHP containers are recreated with the new environment. No image rebuild is required for config-only changes.

---

## Creating a new instance

```bash
./add-site.sh SITE_ID DOMAIN [WP_HOME|ALLOCATION_WEIGHT] [ALLOCATION_WEIGHT]
./up.sh
```

### Examples

```bash
# Production
./add-site.sh blog blog.example.com
./add-site.sh shop shop.example.com https://shop.example.com 2

# Local (add 127.0.0.1 blog.localhost to /etc/hosts)
./add-site.sh blog blog.localhost
./up.sh
```

### `SITE_ID` rules

- Starts with a letter; lowercase letters, numbers, underscores only; max 16 characters.
- Becomes the Docker Compose service name and container suffix.
- Reserved: `db`, `nginx`, `redis`, `certbot`, `phpmyadmin`.

### What `./add-site.sh` does

1. Creates `sites/<id>.env` with a random `DB_PASSWORD` and `SPACES_ENABLED=no` (Spaces off by default).
2. Runs `./generate-env.sh` (nginx vhost, PHP pool, compose service, SQL grants, missing `SPACES_*` backfill).
3. You run `./up.sh` to start the new PHP container; `./provision-sites.sh` creates the database and user.

### Manual creation

Copy [sites/example.env.sample](../sites/example.env.sample) to `sites/<id>.env`, fill in values, then:

```bash
./generate-env.sh
./up.sh
```

---

## Changing instance settings

General workflow:

```text
Edit sites/<id>.env  →  ./generate-env.sh  →  ./up.sh
```

Add `./provision-sites.sh` when database **users or passwords** change. Add `./change-url.sh` when the **live site URL** in the database must change.

### Domain and URL (`DOMAIN`, `WP_HOME`)

**Before WordPress is installed:**

1. Edit `DOMAIN` and `WP_HOME` in `sites/<id>.env`.
2. `./generate-env.sh && ./up.sh`.
3. Point DNS or `/etc/hosts` at this server.

**After WordPress is installed:**

1. Edit `sites/<id>.env` (`DOMAIN`, `WP_HOME`).
2. `./generate-env.sh && ./up.sh`.
3. Update URLs stored in the database:

```bash
./change-url.sh blog https://old.example.com https://new.example.com
```

`change-url.sh` runs `wp search-replace`, flushes rewrites and cache, and handles Elementor if present.

### Database name or user (`DB_NAME`, `DB_USER`)

Best set at creation time. Changing them on a live site requires creating a new database/user, migrating data, and updating the env file. For a fresh instance, edit the env file before the first `./up.sh`.

### Database password (`DB_PASSWORD`)

```bash
# Edit sites/<id>.env — set a new DB_PASSWORD
./generate-env.sh
./up.sh
./provision-sites.sh   # applies new password to MariaDB
```

### Table prefix (`DB_PREFIX`)

**Before install:** change `DB_PREFIX` in `sites/<id>.env`, then `./generate-env.sh && ./up.sh`. WordPress creates tables with the new prefix.

**After install:** changing the prefix alone breaks the site. You must rename every table in that instance's database, then update config:

```bash
./backup.sh

# Example: wp_ → blog_ on instance "blog"
set -a && source .env && set +a
docker compose exec -T -u "${PUID}:${PGID}" blog wp db query \
  "SHOW TABLES LIKE 'wp_%'" | tail -n +2 | while read -r table; do
  new="${table/wp_/blog_}"
  docker compose exec -T -u "${PUID}:${PGID}" blog wp db query \
    "RENAME TABLE \`${table}\` TO \`${new}\`;"
done

# sites/blog.env: DB_PREFIX=blog_
./generate-env.sh && ./up.sh
docker compose exec -T -u "${PUID}:${PGID}" blog wp cache flush
```

No Docker image rebuild or MariaDB volume wipe is required.

### Allocation weight (`ALLOCATION_WEIGHT`)

Higher weight = larger share of `WP_MEM_LIMIT` and `WP_CPU_MILLICORES`. Edit in `sites/<id>.env`, then `./generate-env.sh && ./up.sh`.

### Rotating WordPress auth keys

Delete or replace the eight `AUTH_*` / `*_SALT` lines in `sites/<id>.env` with placeholders, or remove them entirely. Run `./generate-env.sh` to generate new values, then `./up.sh`. All users will need to log in again.

---

## WordPress upgrades

Use **`./upgrade-wordpress.sh`** to update WordPress core. It is the single command for image rebuild, core update, database migration, and cache flush.

### Before you start

1. Run **`./backup.sh`**.
2. To pick up a newer **PHP version or base image**, bump the tag in `Dockerfile` first (e.g. `wordpress:7.1.2-php8.5-fpm-alpine`).

### Run the upgrade

```bash
./upgrade-wordpress.sh              # every instance in sites/*.env
./upgrade-wordpress.sh blog         # one instance
./upgrade-wordpress.sh blog default # several instances
```

### What the script does (in order)

For each selected instance:

1. **`docker compose build`** — rebuild the WordPress PHP image (once, before the loop).
2. **`docker compose up -d`** — restart the stack with the new image.
3. **`wp core check-update`** — show available core updates.
4. **`wp core update`** — download and install the latest WordPress core.
5. **`wp core update-db`** — run database schema updates after a core bump.
6. **`wp cache flush`** — clear that instance's object cache (Redis).

Instances without WordPress installed yet are skipped.

### Manual cache flush (without a full upgrade)

After config changes, URL changes, or restores:

```bash
set -a && source .env && set +a
docker compose exec -T -u "${PUID}:${PGID}" blog wp cache flush
```

`./change-url.sh` and `./restore.sh` already flush cache for the affected instance.

### Plugins and themes

`./upgrade-wordpress.sh` updates **core only**. For plugins and themes, use WP-CLI inside the container or the WordPress admin:

```bash
docker compose exec -T -u "${PUID}:${PGID}" blog wp plugin update --all
docker compose exec -T -u "${PUID}:${PGID}" blog wp theme update --all
```

---

## HTTPS (Let's Encrypt)

Prerequisites per instance:

- Public `DOMAIN` (not `localhost`)
- `WP_HOME` already set to `https://...`
- `EMAIL` set in `.env`
- Port 80 reachable from the internet

```bash
./enable-ssl.sh          # all https-ready instances
./enable-ssl.sh blog     # one instance
```

What happens:

1. Certbot writes certificates to `./certs/live/<domain>/`.
2. `./generate-env.sh` replaces the HTTP vhost with HTTP (redirect + ACME) + HTTPS (TLS) blocks.
3. Port 443 is published via `docker-compose.ssl.yml` (`COMPOSE_FILE` updated in `.env`).
4. A daily cron runs `./renew-ssl.sh` at 04:15.

After certificates exist, `./up.sh` reads `COMPOSE_FILE` from `.env` so port 443 stays published.

If TLS is terminated elsewhere (e.g. Cloudflare), leave instances on HTTP and skip `./enable-ssl.sh`.

---

## Scripts reference

| Script | Purpose |
|---|---|
| `./generate-env.sh` | Regenerate compose, nginx, PHP pools, MariaDB init SQL, secrets; backfill missing `SPACES_*` in site env files |
| `./up.sh` | Start stack (`docker compose up -d`) + `./provision-sites.sh` |
| `./down.sh` | Stop stack |
| `./add-site.sh` | Add `sites/<id>.env` and regenerate |
| `./provision-sites.sh` | Create databases and users from `mysql/init/sites.sql` |
| `./backup.sh` | Dump every instance DB to `backups/` |
| `./restore.sh` | Interactive restore from `backups/*.sql.gz` |
| `./change-url.sh` | Search-replace URL in one instance's database |
| `./enable-ssl.sh` | Issue certificates and enable HTTPS |
| `./renew-ssl.sh` | Renew certificates and reload nginx (cron) |
| `./upgrade-wordpress.sh` | Rebuild image; `wp core update`, `update-db`, and `cache flush` per instance |

### phpMyAdmin (optional)

```bash
docker compose --profile tools up -d
```

Web UI at `http://127.0.0.1:8080`. Log in with that instance's `DB_USER` / `DB_PASSWORD` from `sites/<id>.env`.

### WP-CLI

Run inside an instance container:

```bash
set -a && source .env && set +a
docker compose exec -T -u "${PUID}:${PGID}" blog wp plugin list
docker compose exec -T -u "${PUID}:${PGID}" default wp cache flush
```

Replace `blog` / `default` with your `SITE_ID`.

---

## Backups and restore

- **Automatic:** `./generate-env.sh` installs a daily 03:00 cron for `./backup.sh`.
- **Manual:** `./backup.sh` → `backups/<DB_NAME>_<timestamp>.sql.gz` (30-day retention).
- **Restore:** `./restore.sh` (interactive picker).

Backups are SQL only. Instance files under `sites/<id>/wp-content/` are on the host—include them in your own file backup strategy.

---

## Removing an instance

1. Delete `sites/<id>.env`.
2. `./generate-env.sh` (removes compose service, nginx conf, pool).
3. `./up.sh`.
4. Optionally drop the database manually and remove `sites/<id>/wp-content/`.

---

## Content and data locations

```text
.env                          # stack config
sites/
├── default.env               # instance config
├── default/wp-content/       # themes, plugins, uploads
├── blog.env
└── blog/wp-content/
nginx/conf.d/<id>.conf        # generated vhost
php/pools/<id>.conf           # generated FPM pool
certs/live/<domain>/          # Let's Encrypt (after enable-ssl)
backups/                      # SQL dumps
```

Docker volumes (not on host bind paths):

- `db_data` — all MariaDB data
- `default_html`, `blog_html`, … — WordPress core per instance
- `letsencrypt_www` — ACME webroot shared with nginx

---

## Troubleshooting

### Config change had no effect

Run both `./generate-env.sh` and `./up.sh`. PHP env vars apply only after the container is recreated.

### Site shows wrong content after container restart

Nginx caches upstream DNS. This stack uses Docker's resolver (`127.0.0.11`) and variable `fastcgi_pass` to avoid stale IPs. If routing looks wrong after recreating PHP containers, reload nginx:

```bash
docker compose exec -T nginx nginx -s reload
```

### Logout returns 403 or links point to the wrong domain

Usually caused by mixed Redis cache or wrong nginx upstream. Ensure each instance has a unique `WP_REDIS_DATABASE` (automatic) and run `./generate-env.sh && ./up.sh`. Clear browser cookies for both hostnames.

### Port 443 not listening after SSL

Ensure `COMPOSE_FILE` in `.env` includes `docker-compose.ssl.yml` (set automatically when a cert exists). `./up.sh` sources `.env` before compose. Recreate nginx:

```bash
./up.sh
```

### Permission errors in `wp-content`

Check `PUID`/`PGID` in `.env` match the owner of `sites/<id>/wp-content/`. Re-run `./generate-env.sh` after fixing.

### WordPress asks to install again

- Wrong `DB_PREFIX` vs existing tables.
- Wrong `DB_NAME` / credentials.
- Empty or restored database.

Verify with:

```bash
docker compose exec -T -u "${PUID}:${PGID}" <id> wp db prefix
docker compose exec -T -u "${PUID}:${PGID}" <id> wp core is-installed
```

---

## Quick reference: change → command

| What changed | Commands |
|---|---|
| Stack tuning in `.env` | `./generate-env.sh` → `./up.sh` |
| Site URL/domain in `sites/<id>.env` (live site) | `./generate-env.sh` → `./up.sh` → `./change-url.sh` |
| `DB_PASSWORD` | `./generate-env.sh` → `./up.sh` → `./provision-sites.sh` |
| `DB_PREFIX` (live site) | backup → rename tables → edit env → `./generate-env.sh` → `./up.sh` |
| New instance | `./add-site.sh` → `./up.sh` |
| Enable DigitalOcean Spaces | edit `SPACES_*` in `sites/<id>.env` → `./generate-env.sh` → `docker compose build` → `./up.sh` ([SPACES.md](SPACES.md)) |
| HTTPS | set `WP_HOME` to https → `./enable-ssl.sh` |
| WordPress core update | `./backup.sh` → `./upgrade-wordpress.sh` |
