<?php

if (! defined('ABSPATH')) {
    exit;
}

class DO_Spaces_Uploads {

    private static ?self $instance = null;

    private ?DO_Spaces_S3 $s3 = null;
    private string $prefix = '';
    private string $public_base = '';
    private string $staging_dir = '';
    private bool $enabled = false;

    public static function instance(): self {
        if (self::$instance === null) {
            self::$instance = new self();
        }
        return self::$instance;
    }

    private function __construct() {
        $this->prefix = defined('DO_SPACES_PREFIX') ? trim(DO_SPACES_PREFIX, '/') : '';
        $this->staging_dir = trailingslashit(sys_get_temp_dir()) . 'do-spaces-' . md5(ABSPATH . $this->prefix);
        $this->enabled = defined('DO_SPACES_ENABLED') && DO_SPACES_ENABLED;

        if (! $this->enabled) {
            return;
        }

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
                $this->enabled = false;
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

        $this->public_base = defined('DO_SPACES_PUBLIC_URL') && DO_SPACES_PUBLIC_URL !== ''
            ? rtrim(DO_SPACES_PUBLIC_URL, '/')
            : rtrim($endpoint, '/');

        add_filter('upload_dir', [$this, 'filter_upload_dir']);
        add_filter('wp_generate_attachment_metadata', [$this, 'handle_metadata'], 10, 2);
        add_filter('wp_get_attachment_url', [$this, 'filter_attachment_url'], 10, 2);
        add_filter('get_attached_file', [$this, 'materialize_for_editing'], 10, 2);
        add_action('delete_attachment', [$this, 'delete_attachment']);
    }

    public function is_enabled(): bool {
        return $this->enabled && $this->s3 instanceof DO_Spaces_S3;
    }

    private function s3_client(): DO_Spaces_S3 {
        if (! $this->s3 instanceof DO_Spaces_S3) {
            throw new RuntimeException('DO Spaces is not configured.');
        }
        return $this->s3;
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

        if (! $this->s3_client()->put_file($main_key, $file, $mime)) {
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
                if ($this->s3_client()->put_file($size_key, $size_path, $size_mime)) {
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

        if (! $this->s3_client()->get_to_file($key, $local)) {
            return $file;
        }

        return $local;
    }

    /**
     * Copy one attachment from sites/<id>/wp-content/uploads/ to Spaces.
     *
     * @return string migrated|skipped|missing|failed
     */
    public function migrate_attachment(int $attachment_id, bool $dry_run = false, bool $delete_local = true, bool $force = false): string {
        if (get_post_type($attachment_id) !== 'attachment') {
            return 'missing';
        }

        if (! $force && get_post_meta($attachment_id, '_do_spaces_key', true)) {
            return 'skipped';
        }

        $relative = $this->attachment_relative_path($attachment_id);
        if (! $relative) {
            return 'missing';
        }

        $local_main = $this->local_path_for_relative($relative);
        if (! is_readable($local_main)) {
            return 'missing';
        }

        $main_key = $this->object_key_for_relative($relative);
        $mime = get_post_mime_type($attachment_id) ?: 'application/octet-stream';

        if ($dry_run) {
            return 'migrated';
        }

        if (! $this->is_enabled()) {
            return 'failed';
        }

        if (! $this->s3_client()->put_file($main_key, $local_main, $mime)) {
            return 'failed';
        }

        update_post_meta($attachment_id, '_do_spaces_key', $main_key);
        update_post_meta($attachment_id, '_do_spaces_relative', $relative);

        $metadata = wp_get_attachment_metadata($attachment_id);
        if (! empty($metadata['sizes']) && is_array($metadata['sizes'])) {
            $dir = dirname($relative);
            foreach ($metadata['sizes'] as $size) {
                if (empty($size['file'])) {
                    continue;
                }
                $size_relative = ($dir === '.' ? '' : $dir . '/') . $size['file'];
                $size_local = $this->local_path_for_relative($size_relative);
                if (! is_readable($size_local)) {
                    continue;
                }
                $size_key = $this->object_key_for_relative($size_relative);
                $size_mime = $size['mime-type'] ?? 'image/jpeg';
                if ($this->s3_client()->put_file($size_key, $size_local, $size_mime) && $delete_local) {
                    @unlink($size_local);
                }
            }
        }

        if ($delete_local) {
            @unlink($local_main);
            $this->cleanup_local_upload_path(dirname($local_main));
        }

        return 'migrated';
    }

    public function local_uploads_dir(): string {
        return WP_CONTENT_DIR . '/uploads';
    }

    public function delete_attachment(int $post_id): void {
        $key = get_post_meta($post_id, '_do_spaces_key', true);
        if ($key) {
            $this->s3_client()->delete_object($key);
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
            $this->s3_client()->delete_object($size_key);
        }
    }

    private function object_key_for_path(string $absolute_path): string {
        $relative = ltrim(str_replace($this->staging_dir, '', $absolute_path), '/\\');
        return $this->object_key_for_relative($relative);
    }

    private function object_key_for_relative(string $relative): string {
        $relative = ltrim(str_replace('\\', '/', $relative), '/');
        if ($this->prefix === '') {
            return $relative;
        }
        return $this->prefix . '/' . $relative;
    }

    public function attachment_relative_path(int $attachment_id): string {
        $file = get_post_meta($attachment_id, '_wp_attached_file', true);
        if (! $file) {
            $metadata = wp_get_attachment_metadata($attachment_id);
            $file = $metadata['file'] ?? '';
        }

        return $this->normalize_relative_upload_path((string) $file);
    }

    public function normalize_relative_upload_path(string $path): string {
        $path = str_replace('\\', '/', $path);
        $uploads = $this->local_uploads_dir();

        if (str_starts_with($path, $uploads)) {
            return ltrim(substr($path, strlen($uploads)), '/');
        }

        return ltrim($path, '/');
    }

    public function local_path_for_relative(string $relative): string {
        $relative = $this->normalize_relative_upload_path($relative);
        return $this->local_uploads_dir() . '/' . $relative;
    }

    private function cleanup_local_upload_path(string $directory): void {
        $uploads = $this->local_uploads_dir();
        if (! str_starts_with($directory, $uploads)) {
            return;
        }

        if (is_dir($directory)) {
            @rmdir($directory);
        }

        $parent = dirname($directory);
        while (str_starts_with($parent, $uploads) && $parent !== $uploads) {
            if (! @rmdir($parent)) {
                break;
            }
            $parent = dirname($parent);
        }
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
