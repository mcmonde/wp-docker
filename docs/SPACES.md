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

## Setup

### 1. Create a Space in DigitalOcean

1. Create a Space (e.g. region `nyc3`).
2. Create an **Access Key** (API → Spaces keys).
3. Note the bucket name, region, and endpoint.
4. Optional: enable the Space **CDN** and use the CDN URL as `SPACES_PUBLIC_URL`.

### 2. Configure the instance

Edit `sites/<id>.env`:

```bash
SPACES_ENABLED=yes
SPACES_KEY=your-access-key
SPACES_SECRET=your-secret-key
SPACES_BUCKET=my-wp-uploads
SPACES_REGION=nyc3
SPACES_PREFIX=blog
SPACES_PUBLIC_URL=https://my-wp-uploads.nyc3.cdn.digitaloceanspaces.com
```

| Variable | Required | Description |
|---|---|---|
| `SPACES_ENABLED` | yes | Set to `yes` to enable |
| `SPACES_KEY` | yes | Spaces access key |
| `SPACES_SECRET` | yes | Spaces secret key |
| `SPACES_BUCKET` | yes | Bucket name |
| `SPACES_REGION` | yes | Region slug (`nyc3`, `sgp1`, …) |
| `SPACES_PREFIX` | no | Folder per site inside the bucket (defaults to `<id>`) |
| `SPACES_PUBLIC_URL` | no | CDN or public base URL for browser access |
| `SPACES_ENDPOINT` | no | API endpoint (default: `https://{bucket}.{region}.digitaloceanspaces.com`) |
| `SPACES_PATH_STYLE` | no | Set to `yes` only if your provider requires path-style URLs |

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

## Existing media

This plugin applies to **new uploads** after it is enabled. Files already on disk are not migrated automatically.

Options for old media:

1. Use a migration plugin that supports S3-compatible storage, or
2. Re-upload important media, or
3. Extend the plugin with a WP-CLI migration command (not included yet).

Posts that still reference old local URLs may need a search-replace after migration.

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
