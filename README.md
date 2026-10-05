# WordPress Docker — multiple instances

One Docker Compose stack that runs several WordPress instances on a single machine. Use it locally or on a server.

**Documentation:** [docs/USAGE.md](docs/USAGE.md) (configuration and operations) · [docs/PRODUCTION.md](docs/PRODUCTION.md) (production checklist) · [docs/SPACES.md](docs/SPACES.md) (DigitalOcean Spaces media uploads)

Nginx, Redis, and MariaDB are shared. There is one MariaDB server. Every instance has its own:

- PHP-FPM container
- database and database user
- `wp-content` directory
- Redis key prefix
- Nginx vhost

That database user can read and write only its own database.

## Requirements

- Docker Compose v2
- Linux
- At least 1 vCPU and 2 GB RAM for one instance, plus 2 GB of swap at that size. Each extra instance needs another 0.5 vCPU and 512 MB. See [Site capacity](#site-capacity).

## The `wpd` command

Everything is run through one command, in the style of Laravel's `php artisan`:

```bash
./wpd                 # list every command
./wpd help site:add   # usage and examples for one command
./wpd menu            # numbered menu; pick a command and enter its arguments
./wpd list site       # only the site:* commands
```

Commands are grouped by prefix: `site:*`, `db:*`, `ssl:*`, `wp:*`, `spaces:*`. `./wpd wp <site> ...` runs WP-CLI inside an instance, for example `./wpd wp blog plugin list`. The full list is under [Commands](#commands).

## Setup

```bash
./wpd install
```

`install` runs `./wpd env:generate`, then offers to start the stack. `env:generate` writes `.env` once and creates `sites/default.env` for the first instance. It generates the MariaDB root password, that instance's database password, and the WordPress authentication keys. Each site file also gets a DigitalOcean Spaces block with `SPACES_ENABLED=no` and placeholder credentials (see [Media in DigitalOcean Spaces](#media-in-digitalocean-spaces)). It asks whether WordPress containers should get Docker CPU and RAM caps and whether the stack should use only part of the server (see [Stack budget](#stack-budget-use-only-part-of-the-server)), then checks that the server has capacity for the instances and sizes MariaDB, Redis, and PHP (see [What is tuned](#what-is-tuned)). Later runs keep the secrets, backfill any missing `SPACES_*` keys, and re-tune for the current server and instance count.

On a 2 GB server, add 2 GB of swap before starting the stack.

`.env`, `sites/<id>.env`, `docker-compose.sites.yml`, and `mysql/init/*.sql` contain the secrets and are gitignored. `./wpd site:add` generates the database password for each new instance.

Answer yes to put Docker RAM and CPU caps on each WordPress container, split by `ALLOCATION_WEIGHT`. Answer no to leave WordPress containers uncapped. PHP workers are sized the same way either way, and MariaDB, Redis, and Nginx always keep their limits. Change the choice later by editing `ALLOCATE_RESOURCES` and running `./wpd env:generate` again.

Edit `.env` for `EMAIL`, `PUID`, and `PGID`. Edit `sites/default.env` for the first instance:

- `DOMAIN` is the bare hostname. `localhost` is fine for HTTP on this machine.
- `WP_HOME` is the full site URL, including `http://` or `https://`.

If you changed them, or did not start the stack during install, start it now. The first start builds the WordPress image:

```bash
./wpd up
./wpd status
```

The first instance is served on port 80. With one instance, any host header reaches it. phpMyAdmin stays off until you ask for it:

```bash
docker compose --profile tools up -d
```

It listens on `127.0.0.1:8080`. Log in with that instance's `DB_USER` and `DB_PASSWORD`. That login can see only its own database.

## Add an instance

```bash
./wpd site:add blog blog.example.com
./wpd site:add shop shop.example.com 3
./wpd site:add shop shop.example.com https://shop.example.com 3
./wpd up
```

`SITE_ID` becomes the Compose service name. Point DNS, or a hosts-file entry, at this machine. With two or more instances, an unknown hostname is closed.

On a local machine, use a hostname that resolves here and leave the URL on HTTP:

```bash
./wpd site:add blog blog.localhost
```

Add `127.0.0.1 blog.localhost` to `/etc/hosts`, then open `http://blog.localhost`. `./wpd ssl:enable` skips `localhost` because Let's Encrypt does not issue certificates for it.

Each instance is configured in `sites/<id>.env`. Every instance stores themes, plugins, and uploads in `sites/<id>/wp-content`.

Each instance starts at `ALLOCATION_WEIGHT=1`, so resources are split evenly. The fourth argument, or that key in the site file, raises one instance's share. Weight 3 against a weight-1 instance gives the larger one three quarters of the WordPress RAM, PHP workers, and CPU. A weight also counts as that many instances against the server's capacity. Adding or removing an instance runs `./wpd env:generate`, which recalculates every share.

`./wpd site:add` refuses a new instance when the server is over capacity and removes the half-created site file. For a benchmark, override it with `FORCE_SITES=yes ./wpd site:add ...`.

Remove an instance with `./wpd site:remove blog`. It stops the container, moves `sites/blog.env` to `backups/removed-sites/`, and regenerates the config. Its database and `sites/blog/wp-content` stay until you delete them; the command prints how. Every database is stored in the `db_data` volume.

## Databases

One MariaDB server holds every instance. Each instance gets its own database and its own user. The user is granted privileges only on that database, and `./wpd env:generate` recreates the user so a broader grant cannot remain. An instance cannot read or write another instance's database.

Backups use the MariaDB root password in `.env`. phpMyAdmin on this host uses the same server; an instance login still sees only that instance's database.

## HTTPS

For each public instance, set `WP_HOME` to `https://...` and set `EMAIL` in `.env`. DNS must point here. Then:

```bash
./wpd ssl:enable
./wpd ssl:enable blog
```

With no arguments, every instance that already has an https `WP_HOME` gets a certificate. Port 443 is published after the first certificate exists. Renewal runs daily at 04:15 through `./wpd ssl:renew`.

Each instance with a certificate gets one `nginx/conf.d/<id>.conf` with:

- port 80: ACME webroot plus a redirect to HTTPS (except the challenge path)
- port 443: TLS 1.2/1.3, HSTS, OCSP stapling, WordPress PHP, and the same ACME webroot for renewals

HTTP-only instances keep a single port-80 block. Mixed deployments (some HTTPS, some HTTP) are supported. `./wpd up` reads `COMPOSE_FILE` from `.env` so port 443 stays published after certificates exist.

If Cloudflare or another proxy already terminates TLS, leave the instances on HTTP.

## URL changes

```bash
./wpd site:url blog https://old.example https://new.example
```

This updates that instance's database, Elementor when it is installed, rewrite rules, and that instance's object cache.

## Media in DigitalOcean Spaces

Uploads can be stored in a DigitalOcean Spaces bucket instead of `sites/<id>/wp-content/uploads/`. The image ships a free must-use plugin, **DO Spaces Uploads** (`plugins/do-spaces-uploads/`), that uploads media and thumbnails to Spaces and rewrites attachment URLs; no commercial license is needed.

It is off by default. To enable it for one instance, set `SPACES_ENABLED=yes` and replace the key, secret, and bucket placeholders in `sites/<id>.env`, then:

```bash
./wpd env:generate
docker compose build
./wpd up
```

Move existing uploads with:

```bash
./wpd spaces:migrate blog --dry-run
./wpd spaces:migrate blog
```

See [docs/SPACES.md](docs/SPACES.md) for every variable, bucket permissions, migration options, and troubleshooting.

## WordPress upgrades

Run `./wpd db:backup` first. Bump the base tag in `Dockerfile` when you want a newer PHP or image bundle, then:

```bash
./wpd wp:upgrade
./wpd wp:upgrade blog
./wpd wp:upgrade blog default
```

With no arguments, every instance in `sites/*.env` is updated. Pass one or more site ids to update only those instances. The script rebuilds the WordPress image, restarts the stack, then for each instance runs `wp core update`, `wp core update-db`, and **`wp cache flush`**. See [docs/USAGE.md](docs/USAGE.md#wordpress-upgrades) for the full step list and manual cache commands.

## What is tuned

| Piece | Where it lives |
|---|---|
| Site capacity and host RAM split (see below) | `.env` from `./wpd env:generate` |
| MariaDB buffer pool and connections | `mysql/my.cnf` |
| PHP `memory_limit`, uploads, OPcache | `php/custom.ini` |
| PHP-FPM workers, per instance | `php/pools/<id>.conf` |
| Nginx vhost and upload size, per instance | `nginx/conf.d/<id>.conf` |
| Redis eviction cap | `REDIS_MAXMEMORY` in `.env` |

### Site capacity

Every run of `./wpd env:generate` reads the host's vCPU count (`nproc`) and RAM (`free -m`, where a 2 GB server reports about 1960 MB) and works out how many instances the server can run:

```text
first instance:        1 vCPU and 1800 MB reported RAM (a 2 GB server)
each extra weight-1:   +0.5 vCPU and +512 MB

capacity = 1 + min( (vCPU − 1) ÷ 0.5 , (RAM − 1800) ÷ 512 )    (rounded down)
```

The total of every instance's `ALLOCATION_WEIGHT` must fit within that capacity, or `./wpd env:generate` and `./wpd site:add` stop with an error. Set `FORCE_SITES=yes` (on the command line or in `.env`) to continue anyway, for example for a benchmark.

| Server | Capacity |
|---|---|
| 1 vCPU / 2 GB | 1 |
| 2 vCPU / 2 GB | 1 (RAM-bound) |
| 2 vCPU / 4 GB | 3 (CPU-bound) |
| 4 vCPU / 8 GB | 7 |
| 8 vCPU / 16 GB | 15 |
| 12 vCPU / 16 GB | 23 |

### Stack budget (use only part of the server)

On a shared machine (a workstation running other apps) or to simulate a smaller production server, the stack can be limited to part of the host. The first run of `./wpd env:generate` asks:

```text
This server has 12 CPU cores and 15766MB RAM.
Limit CPU and RAM for this stack? [y/N] y
CPU cores to use (1-12): 2
RAM to use, e.g. 4G or 4096M (at most 15766M): 4G
Stack budget: 2 cores, 4096MB RAM (fits a total site weight of 3).
```

The answers are saved as `STACK_CPU_CORES` and `STACK_RAM_MB` in `.env` (empty means the whole host). When set:

- Capacity, the memory model, and PHP workers below are calculated as if the server had only those cores and that RAM.
- **`STACK_CPU_CORES`** pins every container (MariaDB, Redis, Nginx, phpMyAdmin, and each WordPress instance) to cores `0`–`N−1`, so the whole stack together uses at most N cores.
- **`STACK_RAM_MB`** gives every container a RAM cap without swap, WordPress included even with `ALLOCATE_RESOURCES=no`. The caps plus the 384 MB OS reserve add up to the budget.

On a dedicated server, leave both empty: unused cores cost nothing because workers start only on demand. To change the budget later, edit the two values and run `./wpd env:generate && ./wpd up`. An install that predates this setting is asked once on its next interactive run.

### Memory model

With `AUTO_TUNE=yes` (the default), every run sizes the shared services for the current total weight `W` and writes them to `.env`:

| Piece | Size |
|---|---|
| OS and Docker reserve | 384 MB (not written; kept free) |
| Nginx (`NGINX_MEM_LIMIT`) | 128 MB |
| Redis (`REDIS_MEM_LIMIT`) | 64 + 32·W MB, between 128 and 512. `REDIS_MAXMEMORY` is 75% of it. |
| MariaDB connections (`MAX_CONNECTIONS`) | total PHP workers + 20, at least 30 |
| InnoDB buffer pool (`INNODB_BUFFER_POOL_SIZE`) | 256 + 64·W MB, plus half of any RAM that PHP cannot use, up to a quarter of RAM |
| MariaDB container (`DB_MEM_LIMIT`) | buffer pool + 192 MB + 2 MB per connection |
| WordPress budget (`WP_MEM_LIMIT`) | everything left |

Set `AUTO_TUNE=no` to keep hand-edited values. The script then warns if the planned total exceeds the host's RAM.

### PHP workers, OPcache, and memory_limit

Each instance gets a weighted share of the WordPress budget and of the host's CPU workers (`WORKERS_PER_CPU` × vCPU, default 4 per vCPU):

```text
RAM workers   = (share − OPcache − 32 MB FPM master) ÷ PHP_WORKER_AVG_MB
CPU workers   = WORKERS_PER_CPU × vCPU × weight ÷ total weight
max_children  = the smaller of the two, at least 2 and at most 50
```

- **`PHP_WORKER_AVG_MB`** (default 80) is what a typical worker actually uses. Raise it to 120 or more for WooCommerce or page builders. Estimate it under load with `docker stats --no-stream` (container memory divided by busy workers).
- **`PHP_MEMORY_LIMIT`** (default `256M`) is a per-request ceiling that stops runaway requests. It does not change the worker count.
- **`OPCACHE_MEMORY_MB`** (default 128) is shared by all workers in one container. 128 MB fits almost every site.
- **`PHP_FPM_PM`** defaults to `ondemand`: workers start when requests arrive and stop after 10 seconds idle, so a quiet instance costs only its OPcache and master process. Set `dynamic` to keep spare workers running for busy sites.

With `ALLOCATE_RESOURCES=yes`, each WordPress container also gets a Docker RAM cap equal to its share and a CPU cap equal to its share of `WP_CPU_MILLICORES` (80% of host CPU). With `ALLOCATE_RESOURCES=no` those caps are left off, so a busy instance can use what an idle one does not; worker counts are the same.

`./wpd resources` prints this split for your server, per site: weight, RAM and CPU share, Docker caps, workers, idle workers, estimated peak, and the worst case where every worker reaches `memory_limit`. Add `--live` for current usage from `docker stats`.

Examples with the defaults:

| Server, instances | Workers per instance | MariaDB buffer pool | WordPress budget |
|---|---|---|---|
| 1 vCPU / 2 GB, 1 | 4 | 454 MB | 614 MB |
| 2 vCPU / 4 GB, 3 | 2 | 975 MB | 2001 MB |
| 8 vCPU / 16 GB, 3 | 10 | 3952 MB | 10891 MB |
| 12 vCPU / 16 GB, 3 | 16 | 3952 MB | 10859 MB |

Uploads, Nginx `client_max_body_size`, and FastCGI timeouts all use the same `UPLOAD_MAX` and `FASTCGI_TIMEOUT` values.

Redis requires a password (`REDIS_PASSWORD` in `.env`). Object caching uses the prefix `<id>:`, a dedicated Redis database index per instance (`WP_REDIS_DATABASE`), and `WP_REDIS_PASSWORD`. `WP_REDIS_GRACEFUL` keeps an instance on the database if Redis is down. The drop-in is copied to each instance's `wp-content` when that container starts.

## Backups

`./wpd env:generate` installs a daily 03:00 cron that runs `./wpd db:backup`. Each instance is dumped to `backups/<database>_<timestamp>.sql.gz` and kept for 30 days. Restore one file with `./wpd db:restore`.

## Layout

- `wpd` is the command-line entry point. The scripts it runs live in `bin/`; run them through `./wpd`.
- `docker-compose.yml` is MariaDB, Redis, Nginx, phpMyAdmin (`tools`), and Certbot (`ssl`).
- `docker-compose.sites.yml` is generated and holds one PHP service per instance.
- `docker-compose.ssl.yml` publishes port 443 once a certificate exists.
- `Dockerfile` builds on the official `wordpress:<version>-php<version>-fpm-alpine` image and adds WP-CLI and the Redis Object Cache plugin (both version-pinned and checksum-verified), DO Spaces Uploads, and a PHP-FPM health check. To change a pinned version, update its checksum `ARG` too.
- `docker-entrypoint-wrapper.sh` installs the Redis `object-cache.php` drop-in and the Spaces must-use loader into each instance's `wp-content` on container start.
- `plugins/do-spaces-uploads/` is the Spaces plugin source.
- `docs/` holds [USAGE.md](docs/USAGE.md), [PRODUCTION.md](docs/PRODUCTION.md), and [SPACES.md](docs/SPACES.md).

### Commands

| Command | Purpose |
|---|---|
| `install` | First-time setup: `env:generate`, then offer to start the stack |
| `env:generate` | Create or refresh `.env`, check capacity, size services, and regenerate Compose, Nginx, PHP pools, and database grants |
| `up` / `down` / `restart` | Start, stop, or restart the stack; `up` also runs `db:provision` |
| `status` | Container status and health, sites, and resource budget |
| `logs [SERVICE]` | Follow logs for every service or one |
| `resources [SITE] [--live]` | Memory plan, PHP settings, and each site's RAM/CPU share, caps, workers, OPcache, and estimated peak; `--live` adds `docker stats` |
| `site:list` | Sites with domain, URL, weight, PHP workers, HTTPS, and Spaces |
| `site:add` | Add an instance (refused when over capacity) |
| `site:remove` | Remove an instance from the stack, keeping its database and files |
| `site:url` | Change one instance's URL in its database |
| `db:backup` / `db:restore` | Dump every database / restore one dump |
| `db:provision` | Create or update each instance's database and user |
| `ssl:enable` / `ssl:renew` | Issue / renew Let's Encrypt certificates |
| `wp SITE ARGS...` | Run WP-CLI in an instance |
| `wp:upgrade` | Rebuild the image and update WordPress core |
| `shell SITE` | Open a shell in an instance's container |
| `spaces:migrate` | Move existing uploads to DigitalOcean Spaces |
| `cron:install` | Install the daily 03:00 backup cron (run by `env:generate`) |
| `list` / `help` / `menu` | Command list, per-command help, numbered menu |

Aliases: `start` = `up`, `stop` = `down`, `ps` = `status`, `configure` = `env:generate`, `res` = `resources`. Details for each are in [docs/USAGE.md](docs/USAGE.md#command-reference).

### Content layout

```
sites/
├── default.env
├── default/wp-content/    ← first instance
├── blog.env
└── blog/wp-content/       ← second instance
```
