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

## Setup

```bash
./generate-env.sh
```

That writes `.env` once and creates `sites/default.env` for the first instance. It generates the MariaDB root password, that instance's database password, and the WordPress authentication keys. Each site file also gets `SPACES_ENABLED=no` and empty Spaces credential placeholders (off by default; see [docs/SPACES.md](docs/SPACES.md)). It asks whether WordPress containers should share a CPU and RAM budget. Later runs keep those secrets and backfill any missing `SPACES_*` keys on existing site files.

`.env`, `sites/<id>.env`, `docker-compose.sites.yml`, and `mysql/init/*.sql` contain the secrets and are gitignored. `./add-site.sh` generates the database password for each new instance.

Answer yes to put Docker RAM and CPU caps on each WordPress container, split by `ALLOCATION_WEIGHT`. Answer no to leave WordPress containers uncapped. PHP workers are sized the same way either way, and MariaDB, Redis, and Nginx always keep their limits. Change the choice later by editing `ALLOCATE_RESOURCES` and running `./generate-env.sh` again.

Edit `.env` for `EMAIL`, `PUID`, and `PGID`. Edit `sites/default.env` for the first instance:

- `DOMAIN` is the bare hostname. `localhost` is fine for HTTP on this machine.
- `WP_HOME` is the full site URL, including `http://` or `https://`.

Start the stack. The first start builds the WordPress image:

```bash
./up.sh
```

The first instance is served on port 80. With one instance, any host header reaches it. phpMyAdmin stays off until you ask for it:

```bash
docker compose --profile tools up -d
```

It listens on `127.0.0.1:8080`. Log in with that instance's `DB_USER` and `DB_PASSWORD`. That login can see only its own database.

## Add an instance

```bash
./add-site.sh blog blog.example.com
./add-site.sh shop shop.example.com 3
./add-site.sh shop shop.example.com https://shop.example.com 3
./up.sh
```

`SITE_ID` becomes the Compose service name. Point DNS, or a hosts-file entry, at this machine. With two or more instances, an unknown hostname is closed.

On a local machine, use a hostname that resolves here and leave the URL on HTTP:

```bash
./add-site.sh blog blog.localhost
```

Add `127.0.0.1 blog.localhost` to `/etc/hosts`, then open `http://blog.localhost`. `./enable-ssl.sh` skips `localhost` because Let's Encrypt does not issue certificates for it.

Each instance is configured in `sites/<id>.env`. Every instance stores themes, plugins, and uploads in `sites/<id>/wp-content`.

Each instance starts at `ALLOCATION_WEIGHT=1`, so resources are split evenly. The fourth argument, or that key in the site file, raises one instance's share. Weight 3 against a weight-1 instance gives the larger one three quarters of the WordPress RAM, PHP workers, and CPU. A weight also counts as that many instances against the server's capacity. Adding or removing an instance runs `./generate-env.sh`, which recalculates every share.

`./add-site.sh` refuses a new instance when the server is over capacity and removes the half-created site file. For a benchmark, override it with `FORCE_SITES=yes ./add-site.sh ...`.

Removing an instance from Compose is deleting its `sites/<id>.env` and running `./generate-env.sh`. Its database stays on the MariaDB server until you drop it. Every database is stored in the `db_data` volume.

## Databases

One MariaDB server holds every instance. Each instance gets its own database and its own user. The user is granted privileges only on that database, and `./generate-env.sh` recreates the user so a broader grant cannot remain. An instance cannot read or write another instance's database.

Backups use the MariaDB root password in `.env`. phpMyAdmin on this host uses the same server; an instance login still sees only that instance's database.

## HTTPS

For each public instance, set `WP_HOME` to `https://...` and set `EMAIL` in `.env`. DNS must point here. Then:

```bash
./enable-ssl.sh
./enable-ssl.sh blog
```

With no arguments, every instance that already has an https `WP_HOME` gets a certificate. Port 443 is published after the first certificate exists. Renewal runs daily at 04:15 through `renew-ssl.sh`.

Each instance with a certificate gets one `nginx/conf.d/<id>.conf` with:

- port 80: ACME webroot plus a redirect to HTTPS (except the challenge path)
- port 443: TLS 1.2/1.3, HSTS, OCSP stapling, WordPress PHP, and the same ACME webroot for renewals

HTTP-only instances keep a single port-80 block. Mixed deployments (some HTTPS, some HTTP) are supported. `./up.sh` reads `COMPOSE_FILE` from `.env` so port 443 stays published after certificates exist.

If Cloudflare or another proxy already terminates TLS, leave the instances on HTTP.

## URL changes

```bash
./change-url.sh blog https://old.example https://new.example
```

This updates that instance's database, Elementor when it is installed, rewrite rules, and that instance's object cache.

## WordPress upgrades

Run `./backup.sh` first. Bump the base tag in `Dockerfile` when you want a newer PHP or image bundle, then:

```bash
./upgrade-wordpress.sh
./upgrade-wordpress.sh blog
./upgrade-wordpress.sh blog default
```

With no arguments, every instance in `sites/*.env` is updated. Pass one or more site ids to update only those instances. The script rebuilds the WordPress image, restarts the stack, then for each instance runs `wp core update`, `wp core update-db`, and **`wp cache flush`**. See [docs/USAGE.md](docs/USAGE.md#wordpress-upgrades) for the full step list and manual cache commands.

## What is tuned

| Piece | Where it lives |
|---|---|
| Site capacity and host RAM split (see below) | `.env` from `./generate-env.sh` |
| MariaDB buffer pool and connections | `mysql/my.cnf` |
| PHP `memory_limit`, uploads, OPcache | `php/custom.ini` |
| PHP-FPM workers, per instance | `php/pools/<id>.conf` |
| Nginx vhost and upload size, per instance | `nginx/conf.d/<id>.conf` |
| Redis eviction cap | `REDIS_MAXMEMORY` in `.env` |

### Site capacity

Every run of `./generate-env.sh` reads the host's vCPU count (`nproc`) and RAM (`free -m`, where a 2 GB server reports about 1960 MB) and works out how many instances the server can run:

```text
first instance:        1 vCPU and 1800 MB reported RAM (a 2 GB server)
each extra weight-1:   +0.5 vCPU and +512 MB

capacity = 1 + min( (vCPU − 1) ÷ 0.5 , (RAM − 1800) ÷ 512 )    (rounded down)
```

The total of every instance's `ALLOCATION_WEIGHT` must fit within that capacity, or `./generate-env.sh` and `./add-site.sh` stop with an error. Set `FORCE_SITES=yes` (on the command line or in `.env`) to continue anyway, for example for a benchmark.

| Server | Capacity |
|---|---|
| 1 vCPU / 2 GB | 1 |
| 2 vCPU / 2 GB | 1 (RAM-bound) |
| 2 vCPU / 4 GB | 3 (CPU-bound) |
| 4 vCPU / 8 GB | 7 |
| 8 vCPU / 16 GB | 15 |
| 12 vCPU / 16 GB | 23 |

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

- **`PHP_WORKER_AVG_MB`** (default 80) is what a typical worker actually uses. Raise it to 120 or more for WooCommerce or page builders. Measure it with `docker compose exec <id> ps -o rss=,cmd= -C php-fpm`; RSS is in KB.
- **`PHP_MEMORY_LIMIT`** (default `256M`) is a per-request ceiling that stops runaway requests. It does not change the worker count.
- **`OPCACHE_MEMORY_MB`** (default 128) is shared by all workers in one container. 128 MB fits almost every site.
- **`PHP_FPM_PM`** defaults to `ondemand`: workers start when requests arrive and stop after 10 seconds idle, so a quiet instance costs only its OPcache and master process. Set `dynamic` to keep spare workers running for busy sites.

With `ALLOCATE_RESOURCES=yes`, each WordPress container also gets a Docker RAM cap equal to its share and a CPU cap equal to its share of `WP_CPU_MILLICORES` (80% of host CPU). With `ALLOCATE_RESOURCES=no` those caps are left off, so a busy instance can use what an idle one does not; worker counts are the same.

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

`generate-env.sh` installs a daily 03:00 cron that runs `backup.sh`. Each instance is dumped to `backups/<database>_<timestamp>.sql.gz` and kept for 30 days. Restore one file with `./restore.sh`.

## Layout

- `docker-compose.yml` is MariaDB, Redis, Nginx, phpMyAdmin (`tools`), and Certbot (`ssl`).
- `docker-compose.sites.yml` is generated and holds one PHP service per instance.
- `docker-compose.ssl.yml` publishes port 443 once a certificate exists.
- `./up.sh` and `./down.sh` start and stop the stack.

### Content layout

```
sites/
├── default.env
├── default/wp-content/    ← first instance
├── blog.env
└── blog/wp-content/       ← second instance
```
