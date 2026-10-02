<?php

if (! defined('ABSPATH')) {
    exit;
}

class DO_Spaces_Uploads {

    private static ?self $instance = null;

    private DO_Spaces_S3 $s3;
    private string $prefix;
    private string $public_base;
    private string $staging_dir;

    public static function instance(): self {
        if (self::$instance === null) {
            self::$instance = new self();
        }
        return self::$instance;
    }

    private function __construct() {
        $required = [
            'DO_SPACES_KEY',
            'DO_SPACES_SECRET',
            'DO_SPACES_BUCKET',
            'DO_SPACES_REGION',
        ];
        foreach ($required as $constant) {
            if (! defined($constant) || constant($constant) === '') {
                add_action('admin_notices', static function () use ($constant) {
                    if (! current_user_can('manage_options')) {
                        return;
                    }
                    echo '<div class="notice notice-error"><p>DO Spaces Uploads: missing <code>'
                        . esc_html($constant) . '</code> in WordPress config.</p></div>';
                });
                return;
            }
        }

        $endpoint = defined('DO_SPACES_ENDPOINT') && DO_SPACES_ENDPOINT !== ''
            ? DO_SPACES_ENDPOINT
            : 'https://' . DO_SPACES_BUCKET . '.' . DO_SPACES_REGION . '.digitaloceanspaces.com';

        $this->s3 = new DO_Spaces_S3(
            DO_SPACES_KEY,
            DO_SPACES_SECRET,
            DO_SPACES_BUCKET,
            DO_SPACES_REGION,
            $endpoint,
            defined('DO_SPACES_PATH_STYLE') && DO_SPACES_PATH_STYLE
        );

        $this->prefix = defined('DO_SPACES_PREFIX') ? trim(DO_SPACES_PREFIX, '/') : '';
        $this->public_base = defined('DO_SPACES_PUBLIC_URL') && DO_SPACES_PUBLIC_URL !== ''
            ? rtrim(DO_SPACES_PUBLIC_URL, '/')
            : rtrim($endpoint, '/');
        $this->staging_dir = trailingslashit(sys_get_temp_dir()) . 'do-spaces-' . md5(ABSPATH . $this->prefix);

        add_filter('upload_dir', [$this, 'filter_upload_dir']);
        add_filter('wp_generate_attachment_metadata', [$this, 'handle_metadata'], 10, 2);
        add_filter('wp_get_attachment_url', [$this, 'filter_attachment_url'], 10, 2);
        add_filter('get_attached_file', [$this, 'materialize_for_editing'], 10, 2);
        add_action('delete_attachment', [$this, 'delete_attachment']);
    }

    /**
     * Never write uploads under wp-content/uploads — use a temp staging directory only.
     */
    public function filter_upload_dir(array $dirs): array {
        if (! wp_mkdir_p($this->staging_dir . $dirs['subdir'])) {
            return $dirs;
        }

        $public_base = $this->public_base;
        if ($this->prefix !== '') {
            $public_base .= '/' . $this->prefix;
        }

        $dirs['basedir'] = $this->staging_dir;
        $dirs['path'] = $this->staging_dir . $dirs['subdir'];
        $dirs['baseurl'] = $public_base;
        $dirs['url'] = $public_base . $dirs['subdir'];

        return $dirs;
    }

    public function handle_metadata(array $metadata, int $attachment_id): array {
        $file = get_attached_file($attachment_id);
        if (! $file || ! is_readable($file)) {
            return $metadata;
        }

        $main_key = $this->object_key_for_path($file);
        $mime = get_post_mime_type($attachment_id) ?: 'application/octet-stream';

        if (! $this->s3->put_file($main_key, $file, $mime)) {
            return $metadata;
        }

        update_post_meta($attachment_id, '_do_spaces_key', $main_key);
        if (! empty($metadata['file'])) {
            update_post_meta($attachment_id, '_do_spaces_relative', $metadata['file']);
        }

        $base_dir = trailingslashit(dirname($file));
        if (! empty($metadata['sizes']) && is_array($metadata['sizes'])) {
            foreach ($metadata['sizes'] as $size) {
                if (empty($size['file'])) {
                    continue;
                }
                $size_path = $base_dir . $size['file'];
                if (! is_readable($size_path)) {
                    continue;
                }
                $size_key = $this->object_key_for_path($size_path);
                $size_mime = $size['mime-type'] ?? 'image/jpeg';
                if ($this->s3->put_file($size_key, $size_path, $size_mime)) {
                    @unlink($size_path);
                }
            }
        }

        @unlink($file);
        $this->cleanup_staging_path(dirname($file));

        return $metadata;
    }

    public function filter_attachment_url(string $url, int $post_id): string {
        $key = get_post_meta($post_id, '_do_spaces_key', true);
        if ($key) {
            return $this->public_url($key);
        }
        return $url;
    }

    /**
     * Download from Spaces into staging when WordPress needs a local file (crop, regenerate thumbs).
     */
    public function materialize_for_editing(string $file, int $attachment_id): string {
        if ($file !== '' && file_exists($file)) {
            return $file;
        }

        $key = get_post_meta($attachment_id, '_do_spaces_key', true);
        if (! $key) {
            return $file;
        }

        $relative = get_post_meta($attachment_id, '_do_spaces_relative', true);
        if (! $relative) {
            $relative = $key;
            if ($this->prefix !== '' && str_starts_with($relative, $this->prefix . '/')) {
                $relative = substr($relative, strlen($this->prefix) + 1);
            }
        }

        $local = $this->staging_dir . '/' . ltrim($relative, '/');
        if (file_exists($local)) {
            return $local;
        }

        if (! $this->s3->get_to_file($key, $local)) {
            return $file;
        }

        return $local;
    }

    public function delete_attachment(int $post_id): void {
        $key = get_post_meta($post_id, '_do_spaces_key', true);
        if ($key) {
            $this->s3->delete_object($key);
        }

        $metadata = wp_get_attachment_metadata($post_id);
        if (empty($metadata['sizes']) || empty($metadata['file'])) {
            return;
        }

        $dir = dirname($metadata['file']);
        foreach ($metadata['sizes'] as $size) {
            if (empty($size['file'])) {
                continue;
            }
            $size_key = $this->prefix !== ''
                ? $this->prefix . '/' . $dir . '/' . $size['file']
                : $dir . '/' . $size['file'];
            $this->s3->delete_object($size_key);
        }
    }

    private function object_key_for_path(string $absolute_path): string {
        $relative = ltrim(str_replace($this->staging_dir, '', $absolute_path), '/\\');
        if ($this->prefix === '') {
            return $relative;
        }
        return $this->prefix . '/' . $relative;
    }

    private function public_url(string $object_key): string {
        return $this->public_base . '/' . ltrim($object_key, '/');
    }

    private function cleanup_staging_path(string $directory): void {
        if (! str_starts_with($directory, $this->staging_dir)) {
            return;
        }

        if (is_dir($directory)) {
            @rmdir($directory);
        }

        $parent = dirname($directory);
        while (str_starts_with($parent, $this->staging_dir) && $parent !== $this->staging_dir) {
            if (! @rmdir($parent)) {
                break;
            }
            $parent = dirname($parent);
        }
    }
}
