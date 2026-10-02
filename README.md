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
- About 2 GB RAM for one instance. Each extra instance needs enough of the WordPress memory budget for OPcache and two PHP workers.

## Setup

```bash
./generate-env.sh
```

That writes `.env` once and creates `sites/default.env` for the first instance. It generates the MariaDB root password, that instance's database password, and the WordPress authentication keys. It asks whether WordPress containers should share a CPU and RAM budget. Later runs keep those secrets.

`.env`, `sites/<id>.env`, `docker-compose.sites.yml`, and `mysql/init/*.sql` contain the secrets and are gitignored. `./add-site.sh` generates the database password for each new instance.

Answer yes to split `WP_MEM_LIMIT` and `WP_CPU_MILLICORES` across instances. `WP_CPU_MILLICORES` is 80% of the host CPU cores, with 1000 equal to 1 CPU. Answer no to leave WordPress containers without a CPU or RAM cap. MariaDB, Redis, and Nginx keep the limits in `.env` either way. Change the choice later by editing `ALLOCATE_RESOURCES` and running `./generate-env.sh` again.

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

When allocation is enabled, each instance starts at `ALLOCATION_WEIGHT=1`, so the budget is split evenly. The fourth argument, or that key in the site file, raises one instance's share. Weight 3 against a weight-1 instance gives the larger one three quarters of the WordPress RAM and CPU. Adding or removing an instance runs `./generate-env.sh`, which recalculates every share. When allocation is disabled, new instances do not change WordPress CPU or RAM caps because those caps are omitted.

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
| Host RAM split (DB 35%, WordPress 45%, Redis 10% of safe RAM) | `.env` from `./generate-env.sh` |
| MariaDB buffer pool and connections | `mysql/my.cnf` |
| PHP `memory_limit`, uploads, OPcache | `php/custom.ini` |
| PHP-FPM workers, per instance | `php/pools/<id>.conf` |
| Nginx vhost and upload size, per instance | `nginx/conf.d/<id>.conf` |
| Redis eviction cap | `REDIS_MAXMEMORY` in `.env` |

### Memory model

`./generate-env.sh` reads host RAM, keeps 80% as usable, then splits that budget:

- **MariaDB** gets 35% (`DB_MEM_LIMIT`). InnoDB buffer pool is 70% of that.
- **WordPress** gets 45% (`WP_MEM_LIMIT`), shared across every PHP container.
- **Redis** gets 10% (`REDIS_MEM_LIMIT`). `REDIS_MAXMEMORY` is 75% of that cap.
- **Nginx** stays at 256 MB. The remainder of usable RAM is slack for the OS and optional tools.

When `ALLOCATE_RESOURCES=yes`, each instance receives a share of `WP_MEM_LIMIT` by `ALLOCATION_WEIGHT`. Docker `mem_limit` and `cpus` are set on that PHP container.

PHP-FPM `pm.max_children` is sized from that share minus OPcache and FPM overhead, using `PHP_MEMORY_LIMIT` as the per-worker worst case. Uploads, Nginx `client_max_body_size`, and FastCGI timeouts all use the same `UPLOAD_MAX` and `FASTCGI_TIMEOUT` values.

When `ALLOCATE_RESOURCES=no`, WordPress containers have no Docker RAM or CPU cap. FPM pools are still sized from an even split of the WordPress budget so many instances do not each assume the full host share.

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
