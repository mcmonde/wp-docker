<?php
/**
 * Plugin Name: DO Spaces Uploads
 * Description: Store WordPress media uploads in DigitalOcean Spaces (S3-compatible). No license required.
 * Version: 1.0.0
 * Author: wp-docker stack
 * License: GPL-2.0-or-later
 */

if (! defined('ABSPATH')) {
    exit;
}

if (! defined('DO_SPACES_ENABLED') || ! DO_SPACES_ENABLED) {
    return;
}

require_once __DIR__ . '/includes/class-do-spaces-s3.php';
require_once __DIR__ . '/includes/class-do-spaces-uploads.php';

DO_Spaces_Uploads::instance();
