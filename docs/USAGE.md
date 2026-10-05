# Usage guide

This document explains how to run and configure the multi-instance WordPress Docker stack: environment files, WordPress configuration, adding sites, and day-to-day operations.

All commands go through `./wpd` (see [Command reference](#command-reference)). For a short overview, see [README.md](../README.md). For production deployment, see [PRODUCTION.md](PRODUCTION.md). To store uploads in DigitalOcean Spaces, see [SPACES.md](SPACES.md).

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

**Rule of thumb:** edit `.env` or `sites/<id>.env`, then regenerate. Do not hand-edit generated files—they are overwritten by `./wpd env:generate`.

---

## First-time setup

```bash
./wpd install         # asks for the first site's id and domain, creates sites/<id>.env and .env, checks capacity, sizes services, then offers to start
# Edit .env: EMAIL, PUID, PGID if needed
# Edit sites/<id>.env: DOMAIN, WP_HOME
./wpd up              # builds image, starts stack, creates databases (if not started during install)
./wpd status          # containers, health, and sites
```

The site id (for example `blog`) becomes the container, database, database user, Spaces prefix, and `sites/<id>/` folder name, and is hard to change later. Pressing Enter keeps `default`. Without a terminal, `install` skips the questions and creates `sites/default.env` (database `wordpress`). To name the first site from a script, run `./wpd site:add <id> <domain>` on the fresh checkout instead of `install`.

Open the site in a browser and complete the WordPress install wizard.

Run `./wpd` at any time for the command list, `./wpd help COMMAND` for one command, or `./wpd menu` to pick from a numbered menu. See [Command reference](#command-reference).

The server needs at least 1 vCPU and 2 GB RAM for one instance; on a 2 GB server, add 2 GB of swap first. See [Site capacity in README.md](../README.md#site-capacity) for how many instances a server can hold.

---

## Stack variables (`.env`)

Created on the first `./wpd env:generate` run. Re-running **does not rotate** existing passwords or keys unless they are still placeholders (`change-me`, empty, or too short).

### Identity and contact

| Variable | Description | When to change |
|---|---|---|
| `PUID` | Linux user ID files are owned as inside containers | When host user differs from generated value |
| `PGID` | Linux group ID | Same as `PUID` |
| `PROJECT_NAME` | Docker container name prefix (default `wordpress`) | Rarely |
| `EMAIL` | Let's Encrypt contact address | Before `./wpd ssl:enable` |
| `COMPOSE_FILE` | Compose file list (auto-set) | Do not edit manually; updated when SSL certs exist |

### Secrets

| Variable | Description |
|---|---|
| `MYSQL_ROOT_PASSWORD` | MariaDB root; used by backups and `./wpd db:provision` |
| `REDIS_PASSWORD` | Redis `requirepass`; passed to WordPress as `WP_REDIS_PASSWORD` |

Site database passwords live in `sites/<id>.env`, not in `.env`.

### Resource allocation

| Variable | Description | Default behaviour |
|---|---|---|
| `ALLOCATE_RESOURCES` | `yes` = Docker `mem_limit`/`cpus` on each PHP container, split by weight; `no` = no caps (unless `STACK_RAM_MB` is set). Worker sizing is the same either way. | Asked on first run |
| `STACK_CPU_CORES` | Cores the whole stack may use. Sizing uses this instead of the host count, and every container is pinned to cores `0`–`N−1`. Empty = whole host. | Asked on first run (empty) |
| `STACK_RAM_MB` | RAM the whole stack may use (`4096`, `4096M`, or `4G`). Sizing uses this instead of host RAM, and every container, WordPress included, gets a RAM cap without swap. Empty = whole host. | Asked on first run (empty) |
| `AUTO_TUNE` | `yes` = every `./wpd env:generate` run re-sizes the values marked "auto" below for the current host and total site weight. `no` = keep hand-edited values. | `yes` |
| `FORCE_SITES` | `yes` = allow more total site weight than the server's capacity (for benchmarks). Can also be passed on the command line. | not set (`no`) |
| `WP_MEM_LIMIT` | Total WordPress RAM budget (MB). Auto. | RAM left after the services below and a 384 MB OS reserve |
| `WP_CPU_MILLICORES` | Total WordPress CPU cap budget (`1000` = 1 core). Auto. | 80% of host cores × 1000 |
| `DB_MEM_LIMIT` | MariaDB container RAM cap. Auto. | Buffer pool + 192 MB + 2 MB per connection |
| `REDIS_MEM_LIMIT` | Redis container RAM cap. Auto. | 64 + 32 MB per site weight, 128–512 MB |
| `REDIS_MAXMEMORY` | Redis `maxmemory` setting. Auto. | 75% of `REDIS_MEM_LIMIT` |
| `NGINX_MEM_LIMIT` | Nginx container RAM cap. Auto. | `128m` |

See [Site capacity and Memory model in README.md](../README.md#site-capacity) for the formulas and examples, and [Stack budget](../README.md#stack-budget-use-only-part-of-the-server) for when to limit the stack.

### MariaDB tuning (written to `mysql/my.cnf`)

| Variable | Description |
|---|---|
| `INNODB_BUFFER_POOL_SIZE` | InnoDB buffer pool. Auto: 256 + 64 MB per site weight, plus half of any RAM PHP cannot use, up to a quarter of RAM. |
| `INNODB_LOG_FILE_SIZE` | InnoDB log size. Auto: a quarter of the buffer pool, 128–512 MB. |
| `MAX_CONNECTIONS` | Max MariaDB connections. Auto: total PHP workers + 20, at least 30. |

### PHP / Nginx tuning (written to `php/custom.ini`, PHP pools, and nginx)

| Variable | Description | Default |
|---|---|---|
| `PHP_MEMORY_LIMIT` | PHP `memory_limit`: a per-request ceiling. Does not change worker counts. | `256M` |
| `PHP_WORKER_AVG_MB` | Typical memory one PHP worker uses; workers are counted from this. Use 120+ for WooCommerce or page builders. | `80` |
| `WORKERS_PER_CPU` | Host-wide PHP workers per vCPU, shared by weight | `4` |
| `PHP_FPM_PM` | `ondemand` starts workers on request and stops idle ones after 10 s; `dynamic` keeps spare workers running | `ondemand` |
| `OPCACHE_MEMORY_MB` | OPcache size per PHP container, shared by its workers | `128` |
| `UPLOAD_MAX` | Upload size (`upload_max_filesize`, `post_max_size`, nginx `client_max_body_size`) | `128M` |
| `FASTCGI_TIMEOUT` | PHP `max_execution_time`, nginx FastCGI timeouts | `300` |

### Informational (refreshed every run)

| Variable | Description |
|---|---|
| `HOST_RAM_MB` | Host RAM reported by `free -m` |
| `HOST_CPU_CORES` | Host vCPU count reported by `nproc` |
| `TOTAL_RAM_MB` | RAM the stack is sized for: `STACK_RAM_MB`, or the host RAM |
| `CPU_CORES` | vCPUs the stack is sized for: `STACK_CPU_CORES`, or the host count |

### Changing stack variables

1. Edit `.env`.
2. Run `./wpd env:generate` (refreshes `mysql/my.cnf`, `php/custom.ini`, pools, nginx, compose).
3. Run `./wpd up` (recreates containers if limits changed).

Example — raise upload limit:

```bash
# In .env
UPLOAD_MAX=256M

./wpd env:generate
./wpd up
```

---

## Per-instance variables (`sites/<id>.env`)

Each instance has its own file, e.g. `sites/default.env`, `sites/blog.env`. See also [sites/example.env.sample](../sites/example.env.sample).

### Required (you set or `./wpd site:add` sets)

| Variable | Description | Example |
|---|---|---|
| `DOMAIN` | Hostname Nginx matches (no scheme) | `blog.example.com` |
| `WP_HOME` | Full site URL with `http://` or `https://` | `https://blog.example.com` |
| `DB_NAME` | MariaDB database name | `blog` |
| `DB_USER` | MariaDB user (scoped to `DB_NAME` only) | `blog` |
| `DB_PASSWORD` | MariaDB password | Auto-generated |
| `DB_PREFIX` | WordPress table prefix (must end with `_`) | `wp_` |
| `ALLOCATION_WEIGHT` | Share of WordPress RAM, PHP workers, and CPU; also counts as that many sites against capacity | `1` |

### Auto-generated secrets (do not commit)

| Variable | Description |
|---|---|
| `AUTH_KEY`, `SECURE_AUTH_KEY`, `LOGGED_IN_KEY`, `NONCE_KEY` | WordPress auth keys |
| `AUTH_SALT`, `SECURE_AUTH_SALT`, `LOGGED_IN_SALT`, `NONCE_SALT` | WordPress salts |

Generated on first `./wpd env:generate` if missing or placeholder. Rotating them logs everyone out.

### Auto-generated tuning (written by `./wpd env:generate`)

| Variable | Description |
|---|---|
| `SITE_MEM_LIMIT` | This instance's Docker RAM cap (`unlimited` when `ALLOCATE_RESOURCES=no`) |
| `SITE_CPU_LIMIT` | This instance's Docker CPU cap (`unlimited` when `ALLOCATE_RESOURCES=no`) |
| `SITE_MEM_SHARE_MB` | This instance's weighted share of `WP_MEM_LIMIT`, used to size its workers whether or not it is capped |
| `SITE_CPU_SHARE_MILLI` | This instance's weighted share of `WP_CPU_MILLICORES` (`1000` = 1 core) |
| `PHP_FPM_PM_MAX_CHILDREN` | FPM worker count: the smaller of the RAM-based and CPU-based counts, 2–50 |
| `PHP_FPM_PM_START_SERVERS` | FPM start servers (used only with `PHP_FPM_PM=dynamic`) |
| `PHP_FPM_PM_MIN_SPARE_SERVERS` | FPM min spare (`dynamic` only) |
| `PHP_FPM_PM_MAX_SPARE_SERVERS` | FPM max spare (`dynamic` only) |

These are output, not input: they are recalculated on every run, so edits are overwritten. Change `PHP_WORKER_AVG_MB`, `WORKERS_PER_CPU`, `OPCACHE_MEMORY_MB`, or `ALLOCATION_WEIGHT` instead.

### Spaces (optional, disabled by default)

Every `sites/<id>.env` includes DigitalOcean Spaces keys with **`SPACES_ENABLED=no`**. You do not add them manually.

| When | What happens |
|---|---|
| `./wpd install` on a fresh checkout | `sites/<id>.env` is created for the id you choose (`sites/default.env` without a terminal) and gets the Spaces block |
| `./wpd site:add` | The new site file gets the same block (via `./wpd env:generate`) |
| Later `./wpd env:generate` runs | Missing `SPACES_*` keys are added. Empty keys are filled only while Spaces is disabled; enabled sites are never rewritten. |

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

To enable Spaces: set `SPACES_ENABLED=yes`, replace the key, secret, and bucket placeholders, then run `./wpd env:generate`, `docker compose build`, and `./wpd up`. `./wpd env:generate` refuses to continue if placeholders remain on an enabled site. Full guide: [SPACES.md](SPACES.md).

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

Regenerated on every `./wpd env:generate`. Current defaults:

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

When `SPACES_ENABLED=yes` in `sites/<id>.env`, `./wpd env:generate` also injects `DO_SPACES_KEY`, `DO_SPACES_SECRET`, `DO_SPACES_BUCKET`, and related defines. See [SPACES.md](SPACES.md).

To add custom defines (e.g. `WP_DEBUG`), extend the `WORDPRESS_CONFIG_EXTRA` block in `./wpd env:generate`, then run `./wpd env:generate` and `./wpd up`. Per-site extras are not supported out of the box.

### Official image variables you can add manually

The [WordPress Docker image](https://hub.docker.com/_/wordpress) also supports e.g. `WORDPRESS_DEBUG=1`. Anything added directly to `docker-compose.sites.yml` is lost on the next `./wpd env:generate`—add it in `./wpd env:generate` instead.

### Applying config changes

```bash
# Edit sites/<id>.env (or extend ./wpd env:generate for extra defines)
./wpd env:generate
./wpd up
```

PHP containers are recreated with the new environment. No image rebuild is required for config-only changes.

---

## Creating a new instance

```bash
./wpd site:add SITE_ID DOMAIN [WP_HOME|ALLOCATION_WEIGHT] [ALLOCATION_WEIGHT]
./wpd up
```

### Examples

```bash
# Production
./wpd site:add blog blog.example.com
./wpd site:add shop shop.example.com https://shop.example.com 2

# Local (add 127.0.0.1 blog.localhost to /etc/hosts)
./wpd site:add blog blog.localhost
./wpd up
```

### `SITE_ID` rules

- Starts with a letter; lowercase letters, numbers, underscores only; max 16 characters.
- Becomes the Docker Compose service name and container suffix.
- Reserved: `db`, `nginx`, `redis`, `certbot`, `phpmyadmin`.

### What `./wpd site:add` does

1. Creates `sites/<id>.env` with a random `DB_PASSWORD` and `SPACES_ENABLED=no` (Spaces off by default).
2. Runs `./wpd env:generate` (capacity check, nginx vhost, PHP pool, compose service, SQL grants, missing `SPACES_*` backfill).
3. You run `./wpd up` to start the new PHP container; `./wpd db:provision` creates the database and user.

If the new site would put the total `ALLOCATION_WEIGHT` over the server's capacity (see [Site capacity](../README.md#site-capacity)), `./wpd env:generate` stops and `./wpd site:add` deletes the new `sites/<id>.env`, so nothing changes. To override for a benchmark:

```bash
FORCE_SITES=yes ./wpd site:add blog blog.localhost
```

### Manual creation

Copy [sites/example.env.sample](../sites/example.env.sample) to `sites/<id>.env`, fill in values, then:

```bash
./wpd env:generate
./wpd up
```

---

## Changing instance settings

General workflow:

```text
Edit sites/<id>.env  →  ./wpd env:generate  →  ./wpd up
```

Add `./wpd db:provision` when database **users or passwords** change. Add `./wpd site:url` when the **live site URL** in the database must change.

### Domain and URL (`DOMAIN`, `WP_HOME`)

**Before WordPress is installed:**

1. Edit `DOMAIN` and `WP_HOME` in `sites/<id>.env`.
2. `./wpd env:generate && ./wpd up`.
3. Point DNS or `/etc/hosts` at this server.

**After WordPress is installed:**

1. Edit `sites/<id>.env` (`DOMAIN`, `WP_HOME`).
2. `./wpd env:generate && ./wpd up`.
3. Update URLs stored in the database:

```bash
./wpd site:url blog https://old.example.com https://new.example.com
```

`./wpd site:url` runs `wp search-replace`, flushes rewrites and cache, and handles Elementor if present.

### Database name or user (`DB_NAME`, `DB_USER`)

Best set at creation time. Changing them on a live site requires creating a new database/user, migrating data, and updating the env file. For a fresh instance, edit the env file before the first `./wpd up`.

### Database password (`DB_PASSWORD`)

```bash
# Edit sites/<id>.env — set a new DB_PASSWORD
./wpd env:generate
./wpd up
./wpd db:provision   # applies new password to MariaDB
```

### Table prefix (`DB_PREFIX`)

**Before install:** change `DB_PREFIX` in `sites/<id>.env`, then `./wpd env:generate && ./wpd up`. WordPress creates tables with the new prefix.

**After install:** changing the prefix alone breaks the site. You must rename every table in that instance's database, then update config:

```bash
./wpd db:backup

# Example: wp_ → blog_ on instance "blog"
./wpd wp blog db query \
  "SHOW TABLES LIKE 'wp_%'" | tail -n +2 | while read -r table; do
  new="${table/wp_/blog_}"
  ./wpd wp blog db query \
    "RENAME TABLE \`${table}\` TO \`${new}\`;" < /dev/null
done

# sites/blog.env: DB_PREFIX=blog_
./wpd env:generate && ./wpd up
./wpd wp blog cache flush
```

No Docker image rebuild or MariaDB volume wipe is required.

### Allocation weight (`ALLOCATION_WEIGHT`)

Higher weight = larger share of `WP_MEM_LIMIT`, PHP workers, and `WP_CPU_MILLICORES`, in both allocation modes. A weight of 2 also uses 2 of the server's site capacity. Edit in `sites/<id>.env`, then `./wpd env:generate && ./wpd up`.

### Rotating WordPress auth keys

Delete or replace the eight `AUTH_*` / `*_SALT` lines in `sites/<id>.env` with placeholders, or remove them entirely. Run `./wpd env:generate` to generate new values, then `./wpd up`. All users will need to log in again.

---

## WordPress upgrades

Use **`./wpd wp:upgrade`** to update WordPress core. It is the single command for image rebuild, core update, database migration, and cache flush.

### Before you start

1. Run **`./wpd db:backup`**.
2. To pick up a newer **PHP version or base image**, bump the tag in `Dockerfile` first (e.g. `wordpress:7.1.2-php8.5-fpm-alpine`).

### Run the upgrade

```bash
./wpd wp:upgrade              # every instance in sites/*.env
./wpd wp:upgrade blog         # one instance
./wpd wp:upgrade blog default # several instances
```

### What the script does (in order)

For each selected instance:

1. **`docker compose build --pull`** — rebuild the WordPress PHP image (once, before the loop), pulling the latest security rebuild of the pinned base tag.
2. **`docker compose up -d`** — restart the stack with the new image.
3. **`wp core check-update`** — show available core updates.
4. **`wp core update`** — download and install the latest WordPress core.
5. **`wp core update-db`** — run database schema updates after a core bump.
6. **`wp cache flush`** — clear that instance's object cache (Redis).

Instances without WordPress installed yet are skipped.

### Manual cache flush (without a full upgrade)

After config changes, URL changes, or restores:

```bash
./wpd wp blog cache flush
```

`./wpd site:url` and `./wpd db:restore` already flush cache for the affected instance.

### Plugins and themes

`./wpd wp:upgrade` updates **core only**. For plugins and themes, use WP-CLI inside the container or the WordPress admin:

```bash
./wpd wp blog plugin update --all
./wpd wp blog theme update --all
```

---

## HTTPS (Let's Encrypt)

Prerequisites per instance:

- Public `DOMAIN` (not `localhost`)
- `WP_HOME` already set to `https://...`
- `EMAIL` set in `.env`
- Port 80 reachable from the internet

```bash
./wpd ssl:enable          # all https-ready instances
./wpd ssl:enable blog     # one instance
```

What happens:

1. Certbot writes certificates to `./certs/live/<domain>/`.
2. `./wpd env:generate` replaces the HTTP vhost with HTTP (redirect + ACME) + HTTPS (TLS) blocks.
3. Port 443 is published via `docker-compose.ssl.yml` (`COMPOSE_FILE` updated in `.env`).
4. A daily cron runs `./wpd ssl:renew` at 04:15.

After certificates exist, `./wpd up` reads `COMPOSE_FILE` from `.env` so port 443 stays published.

If TLS is terminated elsewhere (e.g. Cloudflare), leave instances on HTTP and skip `./wpd ssl:enable`.

---

## Command reference

`./wpd` is the single entry point. The scripts it runs live in `bin/`; call them through `./wpd` so paths and messages stay consistent.

```bash
./wpd                  # list every command, grouped
./wpd list db          # one group or prefix
./wpd help site:add    # usage and examples (also: ./wpd site:add --help)
./wpd menu             # numbered menu: pick a command, then type its arguments
```

An unknown or partial command suggests matches (`./wpd site` lists the `site:*` commands). Aliases: `start` = `up`, `stop` = `down`, `ps` = `status`, `configure` = `env:generate`, `res` = `resources`.

| Command | Runs | Purpose |
|---|---|---|
| `install` | `bin/generate-env.sh`, `bin/up.sh` | First-time setup; asks before starting the stack |
| `env:generate` | `bin/generate-env.sh` | Detect host CPU/RAM, check site capacity, size MariaDB/Redis/PHP (`AUTO_TUNE`), and regenerate compose, nginx, PHP pools, MariaDB init SQL, and secrets; backfill missing `SPACES_*` in site env files. `FORCE_SITES=yes` skips the capacity refusal. |
| `up` | `bin/up.sh` | Start stack (`docker compose up -d`) + `db:provision` |
| `down` | `bin/down.sh` | Stop stack |
| `restart` | `bin/down.sh`, `bin/up.sh` | Stop and start the stack |
| `status` | built in | `docker compose ps` (with health), the site list, and the host/stack budget |
| `logs [SERVICE]` | built in | `docker compose logs -f --tail=100`, for all services or one (`blog`, `db`, `nginx`, `redis`) |
| `resources [SITE_ID] [--live]` | built in | Host/budget, memory plan (OS, MariaDB, Redis, Nginx, WordPress), PHP settings, and a per-site table: weight, RAM/CPU share, Docker caps, `max_children`, idle workers, estimated peak (OPcache + 32 MB + workers × `PHP_WORKER_AVG_MB`), and worst case (workers × `memory_limit`). Warns if the estimated peak exceeds the WordPress budget or `MAX_CONNECTIONS` is below the worker total. `--live` adds `docker stats`. |
| `site:list` | built in | Each site's id, domain, URL, weight, PHP workers, HTTPS, and Spaces status |
| `site:add SITE_ID DOMAIN [WP_HOME\|WEIGHT] [WEIGHT]` | `bin/add-site.sh` | Add `sites/<id>.env` and regenerate; removes the new file if the server is over capacity |
| `site:remove SITE_ID [--yes]` | built in | See [Removing an instance](#removing-an-instance) |
| `site:url SITE_ID OLD_URL NEW_URL` | `bin/change-url.sh` | Search-replace URL in one instance's database |
| `db:backup` | `bin/backup.sh` | Dump every instance DB to `backups/` |
| `db:restore` | `bin/restore.sh` | Interactive restore from `backups/*.sql.gz` |
| `db:provision` | `bin/provision-sites.sh` | Create databases and users from `mysql/init/sites.sql` |
| `ssl:enable [SITE_ID ...]` | `bin/enable-ssl.sh` | Issue certificates and enable HTTPS |
| `ssl:renew` | `bin/renew-ssl.sh` | Renew certificates and reload nginx (cron) |
| `wp SITE_ID ARGS...` | built in | WP-CLI in that instance's container, as `PUID:PGID` |
| `wp:upgrade [SITE_ID ...]` | `bin/upgrade-wordpress.sh` | Rebuild image with `--pull` (base image security updates); `wp core update`, `update-db`, and `cache flush` per instance |
| `shell SITE_ID` | built in | `sh` inside that instance's container |
| `spaces:migrate [SITE_ID ...] [options]` | `bin/migrate-spaces.sh` | Move existing uploads to DigitalOcean Spaces (`--dry-run`, `--limit=N`, `--keep-local`); see [SPACES.md](SPACES.md) |
| `cron:install` | `bin/cron-setup.sh` | Add the daily 03:00 backup cron if missing (called by `env:generate`) |

The cron jobs call `bin/backup.sh` and `bin/renew-ssl.sh` directly. Entries from before the scripts moved to `bin/` are rewritten to the new paths the next time `./wpd env:generate` (or `./wpd cron:install`) runs; other cron jobs are left alone.

### phpMyAdmin (optional)

```bash
docker compose --profile tools up -d
```

Web UI at `http://127.0.0.1:8080`. Log in with that instance's `DB_USER` / `DB_PASSWORD` from `sites/<id>.env`.

### WP-CLI

```bash
./wpd wp blog plugin list
./wpd wp default cache flush
./wpd wp blog user create editor editor@example.com --role=editor
```

Replace `blog` / `default` with your `SITE_ID`. Commands run as `PUID:PGID` (with `--allow-root` added when that is root). `./wpd shell blog` opens a shell in the same container.

---

## Backups and restore

- **Automatic:** `./wpd env:generate` installs a daily 03:00 cron for `./wpd db:backup`.
- **Manual:** `./wpd db:backup` → `backups/<DB_NAME>_<timestamp>.sql.gz` (30-day retention).
- **Restore:** `./wpd db:restore` (interactive picker).

Backups are SQL only. Instance files under `sites/<id>/wp-content/` are on the host—include them in your own file backup strategy.

---

## Removing an instance

```bash
./wpd site:remove blog          # asks you to type the site id
./wpd site:remove blog --yes    # no prompt (scripts)
```

It stops and removes the `blog` container, moves `sites/blog.env` to `backups/removed-sites/blog-<timestamp>.env` (so the database password is kept), runs `env:generate` to drop the Compose service, Nginx vhost, and PHP pool, and removes the orphaned container if the stack is running.

Kept until you delete them (the command prints these):

- the database: `docker compose exec db mariadb -u root -p -e 'DROP DATABASE \`blog\`'`
- the files: `sites/blog/`
- the core volume: `docker volume ls | grep blog_html`

The last remaining site cannot be removed, because `env:generate` would recreate a default site.

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

### "supports a total site weight of N" or "below the 1 vCPU / 2 GB minimum"

The instances' total `ALLOCATION_WEIGHT` is more than the server can hold (first instance 1 vCPU and 2 GB, each extra weight-1 instance 0.5 vCPU and 512 MB). Remove an instance, lower a weight, or resize the server and rerun `./wpd env:generate`. If the message says "The stack budget", raise `STACK_CPU_CORES` / `STACK_RAM_MB` in `.env` or empty them. For a benchmark only, rerun with `FORCE_SITES=yes`.

### "Allowed memory size exhausted" or slow pages under load

- **Memory errors:** a request hit `PHP_MEMORY_LIMIT`. Raise it in `.env` (for example `512M`); it does not change worker counts.
- **Requests queue under load:** check `PHP_FPM_PM_MAX_CHILDREN` in `sites/<id>.env`. Workers are capped by CPU (`WORKERS_PER_CPU`) and by RAM (`PHP_WORKER_AVG_MB`). If real worker memory is lower than `PHP_WORKER_AVG_MB`, lower it; estimate it under load with `docker stats --no-stream` (container memory divided by busy workers). Raise the instance's `ALLOCATION_WEIGHT` to give it a larger share.
- **Heavy plugins (WooCommerce, page builders):** set `PHP_WORKER_AVG_MB=120` or more so the RAM limit is realistic.

Run `./wpd env:generate && ./wpd up` after any of these changes.

### PHP container shows `(unhealthy)` in `docker compose ps`

The image's health check asks PHP-FPM for its ping page (`ping.path = /fpm-ping`, written into `php/pools/<id>.conf` by `./wpd env:generate`). Unhealthy means the pool is not answering:

- **Pool files from an older version** have no `ping.path`. Run `./wpd env:generate` and `./wpd up`.
- **All workers busy or hung:** check `docker compose logs <id>` for `max_children` warnings, then restart with `docker compose restart <id>`.

Docker reports the status but does not restart unhealthy containers by itself; `restart: always` only covers containers that exit.

### Config change had no effect

Run both `./wpd env:generate` and `./wpd up`. PHP env vars apply only after the container is recreated.

### Site shows wrong content after container restart

Nginx caches upstream DNS. This stack uses Docker's resolver (`127.0.0.11`) and variable `fastcgi_pass` to avoid stale IPs. If routing looks wrong after recreating PHP containers, reload nginx:

```bash
docker compose exec -T nginx nginx -s reload
```

### Logout returns 403 or links point to the wrong domain

Usually caused by mixed Redis cache or wrong nginx upstream. Ensure each instance has a unique `WP_REDIS_DATABASE` (automatic) and run `./wpd env:generate && ./wpd up`. Clear browser cookies for both hostnames.

### Port 443 not listening after SSL

Ensure `COMPOSE_FILE` in `.env` includes `docker-compose.ssl.yml` (set automatically when a cert exists). `./wpd up` sources `.env` before compose. Recreate nginx:

```bash
./wpd up
```

### Permission errors in `wp-content`

Check `PUID`/`PGID` in `.env` match the owner of `sites/<id>/wp-content/`. Re-run `./wpd env:generate` after fixing.

### WordPress asks to install again

- Wrong `DB_PREFIX` vs existing tables.
- Wrong `DB_NAME` / credentials.
- Empty or restored database.

Verify with:

```bash
./wpd wp <id> db prefix
./wpd wp <id> core is-installed
```

---

## Quick reference: change → command

| What changed | Commands |
|---|---|
| Stack tuning in `.env` | `./wpd env:generate` → `./wpd up` |
| Site URL/domain in `sites/<id>.env` (live site) | `./wpd env:generate` → `./wpd up` → `./wpd site:url` |
| `DB_PASSWORD` | `./wpd env:generate` → `./wpd up` → `./wpd db:provision` |
| `DB_PREFIX` (live site) | backup → rename tables → edit env → `./wpd env:generate` → `./wpd up` |
| New instance | `./wpd site:add` → `./wpd up` |
| Remove an instance | `./wpd site:remove <id>` |
| See how RAM, CPU, workers, and OPcache are split | `./wpd resources` (add `--live` for current usage) |
| `ALLOCATE_RESOURCES`, `ALLOCATION_WEIGHT`, or PHP worker settings | `./wpd env:generate` → `./wpd up` |
| Server resized (CPU or RAM) | `./wpd env:generate` → `./wpd up` (re-detects the host and re-tunes) |
| Limit or unlimit the stack's CPU/RAM | edit `STACK_CPU_CORES` / `STACK_RAM_MB` in `.env` → `./wpd env:generate` → `./wpd up` |
| Enable DigitalOcean Spaces | edit `SPACES_*` in `sites/<id>.env` → `./wpd env:generate` → `docker compose build` → `./wpd up` ([SPACES.md](SPACES.md)) |
| Move existing uploads to Spaces | `./wpd spaces:migrate <id> --dry-run` → `./wpd spaces:migrate <id>` |
| HTTPS | set `WP_HOME` to https → `./wpd ssl:enable` |
| WordPress core update | `./wpd db:backup` → `./wpd wp:upgrade` |
