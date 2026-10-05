<?php

if (! defined('ABSPATH')) {
    exit;
}

if (! defined('WP_CLI') || ! WP_CLI) {
    return;
}

class DO_Spaces_CLI {

    private function require_spaces_enabled(): DO_Spaces_Uploads {
        if (! defined('DO_SPACES_ENABLED') || ! DO_SPACES_ENABLED) {
            WP_CLI::error('DO Spaces is disabled. Set SPACES_ENABLED=yes in sites/<id>.env, run ./wpd env:generate, and ./wpd up.');
        }

        $service = DO_Spaces_Uploads::instance();
        if (! $service->is_enabled()) {
            WP_CLI::error('DO Spaces is not fully configured. Check SPACES_* values in sites/<id>.env.');
        }

        return $service;
    }

    /**
     * Upload existing wp-content/uploads media to DigitalOcean Spaces.
     *
     * ## OPTIONS
     *
     * [--dry-run]
     * : List what would be migrated without uploading or deleting files.
     *
     * [--keep-local]
     * : Upload to Spaces but keep copies under wp-content/uploads/.
     *
     * [--force]
     * : Re-upload attachments that already have Spaces metadata.
     *
     * [--limit=<number>]
     * : Process at most this many attachments. Default: all.
     *
     * [--offset=<number>]
     * : Skip this many attachments first.
     *
     * ## EXAMPLES
     *
     *     wp do-spaces migrate --dry-run
     *     wp do-spaces migrate --limit=50
     *     wp do-spaces migrate --keep-local
     */
    public function migrate(array $args, array $assoc_args): void {
        $service = $this->require_spaces_enabled();
        $dry_run = isset($assoc_args['dry-run']);
        $delete_local = ! isset($assoc_args['keep-local']);
        $force = isset($assoc_args['force']);
        $limit = isset($assoc_args['limit']) ? (int) $assoc_args['limit'] : -1;
        $offset = isset($assoc_args['offset']) ? (int) $assoc_args['offset'] : 0;

        $query_args = [
            'post_type' => 'attachment',
            'post_status' => 'inherit',
            'fields' => 'ids',
            'posts_per_page' => $limit > 0 ? $limit : -1,
            'offset' => $offset,
            'orderby' => 'ID',
            'order' => 'ASC',
        ];

        $attachment_ids = get_posts($query_args);
        if ($attachment_ids === []) {
            WP_CLI::success('No attachments found.');
            return;
        }

        $counts = [
            'migrated' => 0,
            'skipped' => 0,
            'missing' => 0,
            'failed' => 0,
        ];

        foreach ($attachment_ids as $attachment_id) {
            $result = $service->migrate_attachment($attachment_id, $dry_run, $delete_local, $force);
            $counts[$result] = ($counts[$result] ?? 0) + 1;

            $relative = get_attached_file($attachment_id, true);
            WP_CLI::log(sprintf(
                '[%s] #%d %s',
                $result,
                $attachment_id,
                $relative ?: '(no file meta)'
            ));
        }

        WP_CLI::log('');
        WP_CLI::log(sprintf(
            'Done. migrated=%d skipped=%d missing=%d failed=%d%s',
            $counts['migrated'],
            $counts['skipped'],
            $counts['missing'],
            $counts['failed'],
            $dry_run ? ' (dry run)' : ''
        ));

        if ($counts['failed'] > 0) {
            WP_CLI::halt(1);
        }
    }

    /**
     * Show how many attachments are on disk, in Spaces, or missing.
     */
    public function status(array $args, array $assoc_args): void {
        unset($args, $assoc_args);

        if (! defined('DO_SPACES_ENABLED') || ! DO_SPACES_ENABLED) {
            WP_CLI::warning('DO Spaces is disabled for this instance.');
        }

        $uploads_dir = WP_CONTENT_DIR . '/uploads';
        $attachment_ids = get_posts([
            'post_type' => 'attachment',
            'post_status' => 'inherit',
            'fields' => 'ids',
            'posts_per_page' => -1,
        ]);

        $on_spaces = 0;
        $on_disk = 0;
        $missing = 0;

        $service = DO_Spaces_Uploads::instance();

        foreach ($attachment_ids as $attachment_id) {
            $relative = $service->attachment_relative_path($attachment_id);
            $has_spaces = (bool) get_post_meta($attachment_id, '_do_spaces_key', true);
            $local = $relative ? $service->local_path_for_relative($relative) : '';

            if ($has_spaces) {
                $on_spaces++;
            }
            if ($relative && is_readable($local)) {
                $on_disk++;
            }
            if (! $has_spaces && ($relative === '' || ! is_readable($local))) {
                $missing++;
            }
        }

        WP_CLI::log('Attachments total: ' . count($attachment_ids));
        WP_CLI::log('On Spaces: ' . $on_spaces);
        WP_CLI::log('Still on disk: ' . $on_disk);
        WP_CLI::log('Missing locally and not on Spaces: ' . $missing);
    }
}

WP_CLI::add_command('do-spaces', DO_Spaces_CLI::class);
