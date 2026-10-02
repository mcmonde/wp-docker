# DigitalOcean Spaces uploads

This stack includes **DO Spaces Uploads**, a free must-use plugin (GPL-2.0) that stores media in [DigitalOcean Spaces](https://www.digitalocean.com/products/spaces) instead of on the server disk.

No commercial license is required.

---

## How it works

1. WordPress is redirected away from `wp-content/uploads/` to a **temp staging folder** (`/tmp/do-spaces-…/` inside the container).
2. Image thumbnails are generated in that temp folder (WordPress requires a local file for this step).
3. The original and each size are uploaded to Spaces; temp files are deleted immediately.
4. **`sites/<id>/wp-content/uploads/` stays empty** — nothing is stored on your server disk for media.

Themes, plugins, and the database stay on this server. Only **media files** live in Spaces.

If you crop an image or regenerate thumbnails in wp-admin, the plugin briefly downloads the file from Spaces back into temp storage for that operation only.

---

## Default configuration (disabled)

You do **not** need to hand-add Spaces variables to `sites/<id>.env`. They are seeded automatically with Spaces **off**:

| When | What happens |
|---|---|
| First `./generate-env.sh` (no site files yet) | Creates `sites/default.env`, then adds the Spaces block below |
| `./add-site.sh` | Creates `sites/<id>.env` and runs `./generate-env.sh`, which adds the block |
| Every `./generate-env.sh` | Adds any **missing** `SPACES_*` keys. On sites with Spaces disabled, it also fills keys that are present but empty. Sites with `SPACES_ENABLED=yes` are never rewritten. |

Default block (also in [sites/example.env.sample](../sites/example.env.sample)):

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

The uppercase words `SPACES_BUCKET` and `SPACES_REGION` inside the two URLs are tokens. `./generate-env.sh` replaces them with your bucket and region values, so you usually only edit `SPACES_BUCKET` and `SPACES_REGION` and leave the URLs alone. For example, with `SPACES_BUCKET=infosoft-playground` and `SPACES_REGION=sgp1`, the public URL becomes `https://infosoft-playground.sgp1.cdn.digitaloceanspaces.com`.

With `SPACES_ENABLED=no`, uploads stay on the server under `sites/<id>/wp-content/uploads/`, and the placeholder values are ignored. The plugin is still present, so `wp do-spaces status` works for inspection.

If you set `SPACES_ENABLED=yes` while `SPACES_KEY`, `SPACES_SECRET`, or `SPACES_BUCKET` still hold the placeholder text, `./generate-env.sh` stops with an error instead of deploying a broken config.

There is no separate configure command. `./generate-env.sh` is the initializer and backfill step.

---

## Setup

### 1. Create a Space in DigitalOcean

1. Create a Space (e.g. region `sgp1`).
2. Create an **Access Key** (API → Spaces keys).
3. Note the bucket name and region.
4. Enable the Space **CDN** if you keep the default CDN `SPACES_PUBLIC_URL` (see the table below).

### 2. Configure the instance

See [Default configuration (disabled)](#default-configuration-disabled) above. When you are ready to enable Spaces, edit `sites/<id>.env` and replace the placeholders:

```bash
SPACES_ENABLED=yes
SPACES_KEY=DO00EXAMPLEKEY
SPACES_SECRET=example-secret
SPACES_BUCKET=infosoft-playground
SPACES_REGION=sgp1
SPACES_ENDPOINT=https://SPACES_BUCKET.SPACES_REGION.digitaloceanspaces.com
SPACES_PUBLIC_URL=https://SPACES_BUCKET.SPACES_REGION.cdn.digitaloceanspaces.com
SPACES_PREFIX=default
SPACES_PATH_STYLE=no
```

| Variable | Required | Default | Description |
|---|---|---|---|
| `SPACES_ENABLED` | yes | `no` | Set to `yes` to enable |
| `SPACES_KEY` | yes | placeholder | Spaces access key |
| `SPACES_SECRET` | yes | placeholder | Spaces secret key |
| `SPACES_BUCKET` | yes | placeholder | Bucket (Space) name |
| `SPACES_REGION` | yes | `sgp1` | Region slug (`sgp1`, `nyc3`, `fra1`, …) |
| `SPACES_ENDPOINT` | no | bucket API URL | Where the plugin sends uploads and deletes. Keep the default. If empty, the plugin uses the same URL. |
| `SPACES_PUBLIC_URL` | no | bucket CDN URL | Base URL written into image links. If empty, the endpoint URL is used. |
| `SPACES_PREFIX` | no | site id | Folder inside the bucket for this instance |
| `SPACES_PATH_STYLE` | no | `no` | Leave `no` for DigitalOcean |

**`SPACES_ENDPOINT`** is the S3 API address, `https://<bucket>.<region>.digitaloceanspaces.com`. The bucket must be part of the hostname. Do not use the region-only form `https://sgp1.digitaloceanspaces.com` unless you also set `SPACES_PATH_STYLE=yes`.

**`SPACES_PUBLIC_URL`** is what visitors' browsers load. The default CDN URL (`<bucket>.<region>.cdn.digitaloceanspaces.com`) only works after you enable the CDN on the Space in the DigitalOcean control panel. Without the CDN, set it to the origin URL, `https://SPACES_BUCKET.SPACES_REGION.digitaloceanspaces.com`, or leave it empty. A custom domain such as `https://media.example.com` also works.

**`SPACES_PREFIX`** is the folder inside the bucket, not a folder on your server. It defaults to the site id, which is also the name of the `sites/<id>/` folder (`default`, `blog`, …). That keeps instances separate when they share one bucket. You can change it, but do so before uploading media, or run the migration again afterwards.

**`SPACES_PATH_STYLE`** controls the URL style used for API requests. `no` (virtual-hosted style) puts the bucket in the hostname, which is what DigitalOcean uses. `yes` (path style) puts the bucket in the path, as in `https://host/<bucket>/file.jpg`. Only S3-compatible servers such as MinIO need that.

Use a **different `SPACES_PREFIX`** per instance when sharing one bucket:

```text
my-bucket/blog/2026/10/photo.jpg
my-bucket/default/2026/10/photo.jpg
```

### 3. Rebuild and redeploy

The plugin ships in the Docker image:

```bash
./generate-env.sh
docker compose build
./up.sh
```

### 4. Bucket permissions

The Space (or prefix) must allow **public read** for media URLs to work in browsers, unless you use signed URLs (not implemented in this plugin). In the DO control panel, set the bucket or `SPACES_PREFIX` folder to allow public read for uploaded objects.

---

## Verify

Upload an image in WordPress admin, then check:

- The attachment URL uses your `SPACES_PUBLIC_URL` (or bucket URL).
- The file is **not** kept on the server under `sites/<id>/wp-content/uploads/` (except briefly during upload).
- The object appears in the DigitalOcean Space console.

---

## Migrate existing media from wp-content/uploads

Use this when the site already has files under `sites/<id>/wp-content/uploads/` and you want them in Spaces.

### 1. Prepare

```bash
./backup.sh
```

Enable Spaces in `sites/<id>.env`, then rebuild so the migration command is available:

```bash
./generate-env.sh
docker compose build
./up.sh
```

### 2. Check status

```bash
./migrate-spaces.sh blog --dry-run
# or inside the container:
docker compose exec -T -u "${PUID}:${PGID}" blog wp do-spaces status
```

### 3. Run the migration

```bash
# Preview (no uploads, no deletes)
./migrate-spaces.sh blog --dry-run

# Upload everything and remove local copies
./migrate-spaces.sh blog

# One site, first 100 files
./migrate-spaces.sh blog --limit=100

# Keep local copies until you verify Spaces
./migrate-spaces.sh blog --keep-local

# Every Spaces-enabled site
./migrate-spaces.sh
```

The command uploads each attachment and its registered thumbnail sizes, sets Spaces metadata, and by default **deletes local files** under `wp-content/uploads/`.

### 4. Fix hard-coded URLs in post content (if needed)

Attachment URLs in templates use Spaces automatically after migration. Old URLs embedded in **post content** may still point at `/wp-content/uploads/...`. Replace them:

```bash
set -a && source .env && set +a

OLD='http://blog.example.com/wp-content/uploads'
NEW='https://my-wp-uploads.nyc3.cdn.digitaloceanspaces.com/blog'

docker compose exec -T -u "${PUID}:${PGID}" blog wp search-replace "$OLD" "$NEW" --all-tables --skip-columns=guid
docker compose exec -T -u "${PUID}:${PGID}" blog wp cache flush
```

Or use `./change-url.sh` if the whole site URL changed.

### 5. Verify and free disk

```bash
docker compose exec -T -u "${PUID}:${PGID}" blog wp do-spaces status
du -sh sites/blog/wp-content/uploads/
```

`uploads/` should be empty or much smaller after a successful migration without `--keep-local`.

---

## Disable Spaces for an instance

```bash
# sites/<id>.env
SPACES_ENABLED=no
```

Then:

```bash
./generate-env.sh
./up.sh
```

New uploads stay on the server again. Objects already in Spaces are not deleted automatically.

---

## Plugin location

| Path | Purpose |
|---|---|
| `plugins/do-spaces-uploads/` | Source in this repository |
| `/opt/do-spaces-uploads/` | Copy inside the PHP container |
| `wp-content/mu-plugins/do-spaces-uploads.php` | Loader (auto-installed on container start) |

Configuration is injected via `WORDPRESS_CONFIG_EXTRA` in `docker-compose.sites.yml` (from `sites/<id>.env`). Credentials are not stored in the WordPress database.

---

## Troubleshooting

| Problem | Check |
|---|---|
| Upload fails | Spaces key/secret, bucket name, region; PHP container logs |
| URL is local, not CDN | `SPACES_PUBLIC_URL`; `./generate-env.sh && ./up.sh` |
| 403 in browser | Bucket or object ACL / CDN not public for reads |
| Plugin not loading | Rebuild image (`docker compose build`); loader at `mu-plugins/do-spaces-uploads.php` |

```bash
docker compose logs -f blog
docker compose exec -T -u "${PUID}:${PGID}" blog wp plugin list
```

The plugin appears under **Must Use** in wp-admin when the loader is present.
