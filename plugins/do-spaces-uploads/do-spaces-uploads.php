<?php
/**
 * Plugin Name: DO Spaces Uploads
 * Description: Store WordPress media uploads in DigitalOcean Spaces (S3-compatible). No license required.
 * Version: 1.1.0
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
