<?php
/**
 * Plugin Name: DO Spaces Uploads
 * Description: Store WordPress media uploads in DigitalOcean Spaces (S3-compatible). No license required.
 * Version: 1.2.0
 * Author: wp-docker stack
 * License: GPL-2.0-or-later
 */

if (! defined('ABSPATH')) {
    exit;
}

require_once __DIR__ . '/includes/class-do-spaces-s3.php';
require_once __DIR__ . '/includes/class-do-spaces-uploads.php';

if (defined('WP_CLI') && WP_CLI) {
    require_once __DIR__ . '/includes/class-do-spaces-cli.php';
}

DO_Spaces_Uploads::instance();

$do_spaces_flush_pending = static function (): void {
    delete_transient('do_spaces_pending_count');
};
add_action('add_attachment', $do_spaces_flush_pending);
add_action('delete_attachment', $do_spaces_flush_pending);
unset($do_spaces_flush_pending);

if (is_admin()) {
    require_once __DIR__ . '/includes/class-do-spaces-admin.php';
    new DO_Spaces_Admin(DO_Spaces_Uploads::instance());
}
