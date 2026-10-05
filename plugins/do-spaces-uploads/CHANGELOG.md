# Changelog

## 1.2.0

### Added

- Admin page under **Media → DO Spaces**: read-only config summary (secret never shown), connection test, count of media still on the server, and batched upload to Spaces with progress, stop, and keep-local option.
- Admin notice for administrators while server media is waiting and the connection works; dismissible until the count changes.
- `wp do-spaces test` command; `wp do-spaces status` now reports how many attachments are ready to upload.
- `DO_Spaces_Uploads::test_connection()`, `pending_local_ids()`, `config_summary()`.

### Fixed

- Migration was not atomic: if a thumbnail failed, the attachment was still marked as migrated and local files were deleted. Now all files must upload first; on failure the uploaded objects are removed and nothing local changes.
- The unscaled original WordPress keeps for large images (`original_image`) was never uploaded, on new uploads or migration, and was not deleted from Spaces with the attachment.
- With Spaces enabled, media not yet migrated got Spaces URLs and broke on the site. URLs and `srcset` now use `wp-content/uploads/` until the file is uploaded.
- Deleting media that was never uploaded left its files in `wp-content/uploads/`.
- The connection test used `wp_tempnam()`, which is not loaded outside wp-admin.

## 1.1.0

- WP-CLI `wp do-spaces migrate` (`--dry-run`, `--keep-local`, `--force`, `--limit`, `--offset`) and `wp do-spaces status`.
- Shipped in wp-docker commit 11eec9d; the plugin header was not bumped and still read 1.0.0.

## 1.0.0

- Initial release: new uploads staged in temp and pushed to Spaces with thumbnails, Spaces URLs, download-on-edit, delete from Spaces, built-in Signature V4 client.
