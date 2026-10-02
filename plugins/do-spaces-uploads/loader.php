<?php
/**
 * Must-use plugin loader. Copied into wp-content/mu-plugins/ by the container entrypoint.
 */
if (! defined('DO_SPACES_ENABLED') || ! DO_SPACES_ENABLED) {
    return;
}

require '/opt/do-spaces-uploads/do-spaces-uploads.php';
