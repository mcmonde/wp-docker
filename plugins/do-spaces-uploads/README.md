# DO Spaces Uploads

A WordPress plugin that stores the media library in [DigitalOcean Spaces](https://www.digitalocean.com/products/spaces) (or another S3-compatible bucket) instead of `wp-content/uploads/`. It has no dependencies: requests are signed with a small built-in AWS Signature V4 client and sent through the WordPress HTTP API.

- Version: 1.2.0 (see [CHANGELOG.md](CHANGELOG.md))
- License: GPL-2.0-or-later
- Requires: WordPress 6.x or later, PHP 8.0 or later (uses typed properties, `str_starts_with`, and `str_contains`). Developed and tested on WordPress 7.1.2 with PHP 8.5.

This document describes the plugin itself. For how the wp-docker stack configures and deploys it, see [docs/SPACES.md](../../docs/SPACES.md).

---

## Contents

- [What it does](#what-it-does)
- [Installation](#installation)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Admin page](#admin-page)
- [WP-CLI](#wp-cli)
- [Stored data](#stored-data)
- [Code layout](#code-layout)
- [WordPress hooks used](#wordpress-hooks-used)
- [Security](#security)
- [Known limitations](#known-limitations)
- [Development and testing](#development-and-testing)

---

## What it does

- **New uploads** go to Spaces. That includes the main file, every generated thumbnail size and, for large images, the unscaled original WordPress keeps. Nothing stays in `wp-content/uploads/`.
- **Attachment URLs** point at the bucket or at a CDN/custom domain.
- **Existing media** in `wp-content/uploads/` is detected and can be moved to Spaces from wp-admin (batched, with progress) or WP-CLI.
- **Media that has not been moved yet** keeps working: its URLs and `srcset` stay on `wp-content/uploads/` until it is uploaded.
- **Editing** an image (crop, regenerate thumbnails) temporarily downloads the file from Spaces.
- **Deleting** an attachment removes its objects from Spaces, or its local files if it was never uploaded.
- A **connection test** proves the key can write and delete in the bucket before anything is moved.

---

## Installation

The plugin is configured only through PHP constants (see [Configuration](#configuration)). It has no settings form and stores no credentials in the database.

### As a must-use plugin (how wp-docker runs it)

The Docker image copies this folder to `/opt/do-spaces-uploads/`. On container start, `docker-entrypoint-wrapper.sh` copies [`loader.php`](loader.php) to `wp-content/mu-plugins/do-spaces-uploads.php`, and the loader requires `/opt/do-spaces-uploads/do-spaces-uploads.php`. Keeping the code outside `wp-content` means the bind-mounted `wp-content` folder does not hide it and site admins cannot deactivate it.

To use the same layout elsewhere, put this folder somewhere outside `wp-content` and point a one-line loader at it, or copy the folder into `wp-content/mu-plugins/` and add a loader that requires `do-spaces-uploads/do-spaces-uploads.php` (WordPress only auto-loads PHP files directly inside `mu-plugins/`).

### As a regular plugin

Copy the folder to `wp-content/plugins/do-spaces-uploads/` and activate it. The main file already has a valid plugin header. There are no activation or uninstall hooks yet (see [Known limitations](#known-limitations)).

---

## Configuration

Define the constants in `wp-config.php` before `require_once ABSPATH . 'wp-settings.php';`. wp-docker generates them from `sites/<id>.env` through `WORDPRESS_CONFIG_EXTRA`.

```php
define('DO_SPACES_ENABLED', true);
define('DO_SPACES_KEY', 'DO00EXAMPLEKEY');
define('DO_SPACES_SECRET', 'example-secret');
define('DO_SPACES_BUCKET', 'my-bucket');
define('DO_SPACES_REGION', 'sgp1');
define('DO_SPACES_ENDPOINT', 'https://my-bucket.sgp1.digitaloceanspaces.com');
define('DO_SPACES_PUBLIC_URL', 'https://my-bucket.sgp1.cdn.digitaloceanspaces.com');
define('DO_SPACES_PREFIX', 'blog');
define('DO_SPACES_PATH_STYLE', false);
```

| Constant | Required | Default | Purpose |
|---|---|---|---|
| `DO_SPACES_ENABLED` | yes | off | `true` turns offloading on. When off, the plugin changes nothing; the admin page and `wp do-spaces status` still work for inspection. |
| `DO_SPACES_KEY` | yes | | Spaces access key. |
| `DO_SPACES_SECRET` | yes | | Spaces secret key. |
| `DO_SPACES_BUCKET` | yes | | Bucket (Space) name. |
| `DO_SPACES_REGION` | yes | | Region slug used for signing, e.g. `sgp1`, `nyc3`, `fra1`. |
| `DO_SPACES_ENDPOINT` | no | `https://<bucket>.<region>.digitaloceanspaces.com` | S3 API address. Only the host is used: requests always go to `https://<host>` on port 443. |
| `DO_SPACES_PUBLIC_URL` | no | the endpoint | Base URL written into media links, e.g. the Spaces CDN URL or a custom domain. |
| `DO_SPACES_PREFIX` | no | empty | Folder inside the bucket, so several sites can share one bucket. Leading and trailing slashes are trimmed. |
| `DO_SPACES_PATH_STYLE` | no | `false` | `false` puts the bucket in the hostname (DigitalOcean). `true` puts it in the path (`https://host/<bucket>/key`), for MinIO-style servers. |

If `DO_SPACES_ENABLED` is true but any required constant is missing or empty, the plugin stays off and shows administrators an error notice naming the constant.

Object keys are `<prefix>/<year>/<month>/<file>`, matching the relative path WordPress would have used under `uploads/`. For example, with prefix `blog`, `2026/10/photo.jpg` becomes `blog/2026/10/photo.jpg`, served at `<public url>/blog/2026/10/photo.jpg`.

### Bucket requirements

- Visitors load media straight from the public URL, so objects must be publicly readable. The plugin does not send an ACL header (`x-amz-acl`) and does not sign URLs; public reads must come from the bucket or prefix settings in DigitalOcean.
- The key needs write and delete permission on the bucket. The connection test checks both.
- If `DO_SPACES_PUBLIC_URL` is the Spaces CDN URL, the CDN must be enabled on the Space.

---

## How it works

### New uploads

1. The `upload_dir` filter points `basedir`/`path` at a temp staging folder (`<sys_get_temp_dir()>/do-spaces-<md5(ABSPATH . prefix)>/<year>/<month>`), and `baseurl`/`url` at `<public url>/<prefix>`.
2. WordPress writes the file and its thumbnails into staging as usual.
3. On `wp_generate_attachment_metadata`, the plugin uploads the main file. If that succeeds it saves `_do_spaces_key` and `_do_spaces_relative`, uploads each thumbnail and the `original_image` (deleting each staged copy after it uploads), then deletes the staged main file and empty folders.
4. If the main upload fails, the metadata is returned unchanged and nothing is marked. The files stay in staging, which is temporary and not served.

### URLs

- `wp_get_attachment_url`: attachments with `_do_spaces_key` get `<public url>/<key>`. Attachments without it whose file still exists in `wp-content/uploads/` get `content_url('uploads/...')`. Anything else keeps the URL WordPress built.
- `wp_calculate_image_srcset`: for media still on the server, rewrites each source from the Spaces base back to `content_url('uploads')`. For migrated media the default `srcset` is already correct, because `upload_dir` points at Spaces.

### Editing

`get_attached_file`: if the file is not on disk but the attachment has `_do_spaces_key`, the object is downloaded into staging and that path is returned. Crop, rotate and thumbnail regeneration then work on the local copy.

### Moving existing media (`migrate_attachment`)

Per attachment, all or nothing:

1. Skip it if it already has `_do_spaces_key` (unless forced) or its main file is not in `wp-content/uploads/`.
2. Collect the main file and every readable thumbnail and `original_image`.
3. Upload them one by one. On the first failure, delete the objects already uploaded for this attachment and return `failed`. No meta is written and no local files are touched.
4. When everything uploaded, write `_do_spaces_key` and `_do_spaces_relative`, then optionally delete the local files and empty year/month folders.

It returns one of `migrated`, `skipped`, `missing` or `failed`.

### Deleting

`delete_attachment`:

- Migrated attachments have the main object, every size and `original_image` deleted from Spaces.
- Attachments still on the server have their files removed from `wp-content/uploads/`, because WordPress itself would look for them in staging.

### Detecting server media (`pending_local_ids`)

Pages through attachments 200 at a time with `meta_query _do_spaces_key NOT EXISTS` and keeps those whose main file is readable under `WP_CONTENT_DIR/uploads`. It takes an optional limit and a list of IDs to exclude, which the admin page uses to skip failures.

### Connection test (`test_connection`)

PUTs a 2-byte object `<prefix>/.do-spaces-check-<random>` and then DELETEs it. It returns `['ok' => bool, 'message' => string]` and tells you whether the upload or the delete failed.

---

## Admin page

**Media → DO Spaces** (`upload.php?page=do-spaces`), for users with `manage_options`. It is loaded only when `is_admin()`, which includes `admin-ajax.php`.

| Section | Behaviour |
|---|---|
| Status | Enabled or disabled, bucket, region, endpoint, public URL, prefix, and the access key masked to its first 4 characters. The secret is never output. |
| Connection | Result of `test_connection()`, cached for 1 hour when it passes and 5 minutes when it fails. **Test again** re-runs it over AJAX. Adding `&retest=1` to the URL forces a fresh test on load. |
| Media still on this server | `count(pending_local_ids())`, recomputed on every page load. |
| Upload server media to Spaces | Shown only when enabled, the connection is OK and the count is above 0. JavaScript calls `do_spaces_migrate_batch` repeatedly. Each call migrates up to 5 attachments and returns per-result counts, failed IDs and a `more` flag. Failed IDs are sent back as `exclude` so they are not retried in the same run. Options: keep local copies, and stop after the current batch. |

**Notice.** On other admin screens, administrators see "N media files are still stored on this server…" with a link to the page. It appears only when Spaces is enabled, the connection test passes and N > 0. Dismissing it saves N in user meta, and it stays hidden until N changes.

AJAX actions all require `manage_options` and the `do_spaces_admin` nonce:

| Action | Purpose |
|---|---|
| `do_spaces_test` | Re-run the connection test and refresh the cache |
| `do_spaces_migrate_batch` | Migrate the next batch. POST fields: `keep_local` (`1`/`0`) and `exclude` (comma-separated IDs). |
| `do_spaces_dismiss` | Save the dismissed count for the notice |

---

## WP-CLI

Registered as `wp do-spaces` when WP-CLI is loaded.

| Command | Description |
|---|---|
| `wp do-spaces test` | Upload and delete a test object. Exits non-zero on failure. |
| `wp do-spaces status` | Totals: attachments, on Spaces, still on disk, missing in both places, and ready to upload. Works with Spaces disabled. |
| `wp do-spaces migrate [--dry-run] [--keep-local] [--force] [--limit=<n>] [--offset=<n>]` | Move existing media. `--force` re-uploads attachments that already have Spaces meta. Exits 1 if any attachment failed. |

In wp-docker these run as `./wpd wp <site> do-spaces …`, and `./wpd spaces:migrate [site] [flags]` wraps `migrate` for one or every Spaces-enabled site.

---

## Stored data

| Type | Name | Contents |
|---|---|---|
| Post meta | `_do_spaces_key` | Object key of the main file. Its presence means "this attachment lives in Spaces". |
| Post meta | `_do_spaces_relative` | Path relative to `uploads/`, e.g. `2026/10/photo-scaled.jpg`. Used to rebuild the staging path when downloading for edits. |
| Transient | `do_spaces_connection` | Last connection test result |
| Transient | `do_spaces_pending_count` | Cached count for the admin notice (10 minutes). Cleared on `add_attachment`, `delete_attachment` and every successful migration. |
| User meta | `do_spaces_notice_dismissed` | Count at which the user dismissed the notice |

Nothing else is written to the database. Credentials live only in constants.

To make WordPress serve an attachment locally again, delete its `_do_spaces_key` (and `_do_spaces_relative`) and make sure the files exist in `wp-content/uploads/`.

---

## Code layout

| File | Class | Role |
|---|---|---|
| `do-spaces-uploads.php` | | Plugin header and bootstrap: loads the S3 client and service, the CLI when `WP_CLI`, and the admin class when `is_admin()`. Clears the pending-count cache when attachments are added or deleted. |
| `loader.php` | | One-line must-use loader used by wp-docker (`/opt/do-spaces-uploads/…`) |
| `includes/class-do-spaces-s3.php` | `DO_Spaces_S3` | Minimal S3 client: `put_file`, `delete_object` (200, 204 and 404 all count as success), `get_to_file`. Signature V4, sent through `wp_remote_request` with a 120-second timeout. |
| `includes/class-do-spaces-uploads.php` | `DO_Spaces_Uploads` | Singleton service: config, hooks, URL rewriting, migration, detection, connection test, deletion |
| `includes/class-do-spaces-admin.php` | `DO_Spaces_Admin` | Media → DO Spaces page, notice, AJAX handlers. Inline JavaScript, no build step. |
| `includes/class-do-spaces-cli.php` | `DO_Spaces_CLI` | `wp do-spaces test`, `status` and `migrate` |

Public methods on `DO_Spaces_Uploads` that the admin and CLI rely on: `instance()`, `is_enabled()`, `migrate_attachment()`, `pending_local_ids()`, `test_connection()`, `config_summary()`, `attachment_relative_path()`, `local_path_for_relative()`, `normalize_relative_upload_path()`, `local_uploads_dir()`.

---

## WordPress hooks used

All hooks below are registered only when Spaces is enabled and fully configured, except the admin and cache ones.

| Hook | Type | Callback |
|---|---|---|
| `upload_dir` | filter | Redirect writes to staging and URLs to Spaces |
| `wp_generate_attachment_metadata` | filter | Upload a new attachment and its sizes |
| `wp_get_attachment_url` | filter | Spaces URL for migrated media, local URL for pending media |
| `wp_calculate_image_srcset` | filter | Point `srcset` back to local files for pending media |
| `get_attached_file` | filter | Download from Spaces for editing |
| `delete_attachment` | action | Delete the objects, or the local files for pending media |
| `add_attachment`, `delete_attachment` | action | Clear the pending-count cache (always registered) |
| `admin_menu`, `admin_notices`, `wp_ajax_*` | action | Admin page, notice, AJAX (admin only) |
| `admin_notices` | action | Missing-constant error (registered from the constructor) |

The plugin does not fire any hooks of its own yet.

---

## Security

- Admin page, notice and AJAX require `manage_options`. AJAX also checks the `do_spaces_admin` nonce.
- The secret is never output. The access key is masked to 4 characters. Config is read-only in the UI.
- The connection test object uses a random name under the configured prefix and is deleted right away.
- Output on the admin page is escaped with `esc_html`, `esc_url` and `wp_json_encode`. AJAX input is cast to `int` or compared to fixed values.
- Every PHP file starts with an `ABSPATH` guard.

---

## Known limitations

These are worth addressing if this becomes a standalone plugin.

| Area | Limitation |
|---|---|
| Configuration | Constants only. There is no settings screen, no encrypted option storage and no per-site network settings. |
| Other files in `uploads/` | `upload_dir` is redirected for every caller, not just the media library. Plugins that write their own files through `wp_upload_dir()` (for example page-builder CSS caches, form uploads, export files) end up in temp staging, and their URLs point at Spaces, where those files never arrive. |
| Image editor | New files the image editor saves (e.g. `photo-e1696500000.jpg`) go through `wp_update_attachment_metadata`, not `wp_generate_attachment_metadata`, so they are not uploaded. Not tested yet. |
| Large files | `put_file` reads the whole file into memory and sends a single PUT. There is no multipart or streaming upload, so file size is bounded by PHP `memory_limit` and a 5 GB single-PUT limit. |
| Object headers | No `Cache-Control`, `Content-Disposition` or ACL headers are sent. Public access depends on bucket settings. |
| Endpoint | Always `https://` on port 443; any port in `DO_SPACES_ENDPOINT` is ignored. |
| Private media | No signed or expiring URLs. |
| Old URLs in content | Links already in post content (`/wp-content/uploads/...`) are not rewritten. A `search-replace` is needed after migrating. |
| Disable or uninstall | Turning it off does not bring media back from Spaces, and there are no uninstall or activation hooks. Migrated attachments keep Spaces URLs only while the plugin is active. |
| Multisite | Not tested. |
| Background processing | Migration runs in the request (AJAX batches of 5 or WP-CLI). There is no queue or cron. |
| Hooks and i18n | No custom actions or filters. Most strings are not translatable and there is no text domain. |

---

## Development and testing

There is no build step and no Composer dependencies. Lint with the same PHP as production:

```bash
docker run --rm -v "$PWD/plugins:/p:ro" wordpress:7.1.2-php8.5-fpm-alpine \
  sh -c 'for f in $(find /p -name "*.php"); do php -l "$f"; done'
```

### Testing without a real Space

Run a throwaway WordPress (separate container names and network, never the production stack) with the plugin mounted at `/opt/do-spaces-uploads`, the loader in `mu-plugins`, and the constants pointing at a fake host such as `https://fake-space.test`. Then add a test-only must-use plugin that answers S3 requests from the filesystem:

```php
<?php
// wp-content/mu-plugins/00-fake-s3.php (test environments only)
add_filter('pre_http_request', function ($pre, $args, $url) {
    if (! str_contains($url, 'fake-space.test')) {
        return $pre;
    }
    $file = '/tmp/fakes3' . urldecode((string) parse_url($url, PHP_URL_PATH));
    $code = 200;
    $body = '';
    if (get_option('fakes3_down')) {
        $code = 403;
    } elseif ($args['method'] === 'PUT') {
        if (get_option('fakes3_failpat') && str_contains($file, get_option('fakes3_failpat'))) {
            $code = 500;
        } else {
            @mkdir(dirname($file), 0777, true);
            file_put_contents($file, $args['body']);
        }
    } elseif ($args['method'] === 'DELETE') {
        @unlink($file);
        $code = 204;
    } elseif ($args['method'] === 'GET') {
        is_file($file) ? $body = file_get_contents($file) : $code = 404;
    }
    return ['headers' => [], 'body' => $body, 'response' => ['code' => $code, 'message' => ''], 'cookies' => [], 'filename' => null];
}, 10, 3);
```

- `wp option update fakes3_down 1` simulates bad credentials.
- `wp option update fakes3_failpat -150x150` makes every matching key fail, to exercise rollback.
- To create "existing server media", temporarily move the loader out of `mu-plugins`, run `wp media import`, then put it back.

This skips request signing. To test signing, use a real Space or an S3-compatible server with TLS on port 443.

Checklist used for 1.2.0:

- [ ] `wp do-spaces test` passes; fails with `fakes3_down`
- [ ] `status` counts match the files in `uploads/`
- [ ] Admin page shows config without the secret; upload button hidden when the connection fails
- [ ] Batch upload with one forced failure: others migrate, the failed one stays local and unmarked
- [ ] Thumbnail failure rolls back the objects already uploaded for that attachment
- [ ] Large image: `-scaled` file, sizes and `original_image` all uploaded
- [ ] New upload with Spaces on: nothing left in `uploads/` or staging
- [ ] Pending media URL and `srcset` use `/wp-content/uploads/`
- [ ] Deleting migrated media removes all objects; deleting pending media removes local files
- [ ] Notice shows the right count, hides after dismiss, and returns when the count changes
- [ ] AJAX rejects a bad nonce and non-admin users
