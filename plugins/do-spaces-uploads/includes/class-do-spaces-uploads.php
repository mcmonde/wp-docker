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
        add_filter('wp_calculate_image_srcset', [$this, 'filter_srcset'], 10, 5);
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
        foreach ($this->extra_files($metadata) as [$name, $extra_mime]) {
            $extra_path = $base_dir . $name;
            if (! is_readable($extra_path)) {
                continue;
            }
            if ($this->s3_client()->put_file($this->object_key_for_path($extra_path), $extra_path, $extra_mime ?: $mime)) {
                @unlink($extra_path);
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
        $local_base = $this->local_base_url_if_pending($post_id);
        if ($local_base !== null) {
            return $local_base . '/' . $this->attachment_relative_path($post_id);
        }
        return $url;
    }

    /**
     * upload_dir points at Spaces, so srcset for media still on this server must be pointed back.
     */
    public function filter_srcset(array $sources, array $size_array, string $image_src, array $image_meta, int $attachment_id): array {
        $local_base = $this->local_base_url_if_pending($attachment_id);
        if ($local_base === null) {
            return $sources;
        }
        $spaces_base = $this->public_base . ($this->prefix !== '' ? '/' . $this->prefix : '');
        foreach ($sources as $width => $source) {
            if (str_starts_with($source['url'], $spaces_base . '/')) {
                $sources[$width]['url'] = $local_base . substr($source['url'], strlen($spaces_base));
            }
        }
        return $sources;
    }

    private function local_base_url_if_pending(int $attachment_id): ?string {
        if (get_post_meta($attachment_id, '_do_spaces_key', true)) {
            return null;
        }
        $relative = $this->attachment_relative_path($attachment_id);
        if ($relative === '' || ! is_readable($this->local_path_for_relative($relative))) {
            return null;
        }
        return content_url('uploads');
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
     * Thumbnails and the unscaled original WordPress keeps for large images, as [file name, mime].
     *
     * @return array<int, array{0: string, 1: string}>
     */
    private function extra_files($metadata): array {
        $files = [];
        if (! is_array($metadata)) {
            return $files;
        }
        if (! empty($metadata['sizes']) && is_array($metadata['sizes'])) {
            foreach ($metadata['sizes'] as $size) {
                if (! empty($size['file'])) {
                    $files[$size['file']] = [$size['file'], (string) ($size['mime-type'] ?? '')];
                }
            }
        }
        if (! empty($metadata['original_image'])) {
            $files[$metadata['original_image']] = [$metadata['original_image'], ''];
        }
        return array_values($files);
    }

    /**
     * Copy one attachment from sites/<id>/wp-content/uploads/ to Spaces. All of its files are
     * uploaded before anything is marked or deleted; on any failure the uploaded objects are removed.
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

        $mime = get_post_mime_type($attachment_id) ?: 'application/octet-stream';
        $files = [[$relative, $local_main, $mime]];

        $dir = dirname($relative);
        foreach ($this->extra_files(wp_get_attachment_metadata($attachment_id)) as [$name, $extra_mime]) {
            $extra_relative = ($dir === '.' ? '' : $dir . '/') . $name;
            $extra_local = $this->local_path_for_relative($extra_relative);
            if (is_readable($extra_local)) {
                $files[] = [$extra_relative, $extra_local, $extra_mime ?: $mime];
            }
        }

        if ($dry_run) {
            return 'migrated';
        }

        if (! $this->is_enabled()) {
            return 'failed';
        }

        $uploaded = [];
        foreach ($files as [$file_relative, $file_local, $file_mime]) {
            $key = $this->object_key_for_relative($file_relative);
            if (! $this->s3_client()->put_file($key, $file_local, $file_mime)) {
                foreach ($uploaded as $done_key) {
                    $this->s3_client()->delete_object($done_key);
                }
                return 'failed';
            }
            $uploaded[] = $key;
        }

        update_post_meta($attachment_id, '_do_spaces_key', $uploaded[0]);
        update_post_meta($attachment_id, '_do_spaces_relative', $relative);
        delete_transient('do_spaces_pending_count');

        if ($delete_local) {
            foreach ($files as [, $file_local]) {
                @unlink($file_local);
            }
            $this->cleanup_local_upload_path(dirname($local_main));
        }

        return 'migrated';
    }

    /**
     * Attachments not yet in Spaces whose main file is still in wp-content/uploads/.
     *
     * @param int[] $exclude
     * @return int[]
     */
    public function pending_local_ids(int $limit = -1, array $exclude = []): array {
        $pending = [];
        $page = 1;
        do {
            $ids = get_posts([
                'post_type' => 'attachment',
                'post_status' => 'inherit',
                'fields' => 'ids',
                'posts_per_page' => 200,
                'paged' => $page,
                'orderby' => 'ID',
                'order' => 'ASC',
                'post__not_in' => array_map('intval', $exclude),
                'no_found_rows' => true,
                'meta_query' => [
                    ['key' => '_do_spaces_key', 'compare' => 'NOT EXISTS'],
                ],
            ]);
            foreach ($ids as $id) {
                $relative = $this->attachment_relative_path((int) $id);
                if ($relative !== '' && is_readable($this->local_path_for_relative($relative))) {
                    $pending[] = (int) $id;
                    if ($limit > 0 && count($pending) >= $limit) {
                        return $pending;
                    }
                }
            }
            $page++;
        } while (count($ids) === 200);

        return $pending;
    }

    /**
     * Uploads and deletes a small object to prove the key can write to the bucket and prefix.
     *
     * @return array{ok: bool, message: string}
     */
    public function test_connection(): array {
        if (! $this->is_enabled()) {
            return ['ok' => false, 'message' => 'Spaces is disabled or missing settings.'];
        }

        $key = $this->object_key_for_relative('.do-spaces-check-' . wp_generate_password(8, false));
        $tmp = tempnam(sys_get_temp_dir(), 'do-spaces-check');
        if ($tmp === false || file_put_contents($tmp, 'ok') === false) {
            return ['ok' => false, 'message' => 'Could not write a temporary file for the test.'];
        }
        $put = $this->s3_client()->put_file($key, $tmp, 'text/plain');
        @unlink($tmp);
        if (! $put) {
            return ['ok' => false, 'message' => 'Upload test failed. Check the key, secret, bucket, region, and endpoint, and that the key can write to this bucket.'];
        }
        if (! $this->s3_client()->delete_object($key)) {
            return ['ok' => false, 'message' => 'Upload worked but deleting the test object failed. The key needs delete permission so removed media is cleaned up.'];
        }
        return ['ok' => true, 'message' => 'Upload and delete worked.'];
    }

    /**
     * Non-secret settings for display.
     *
     * @return array<string, string>
     */
    public function config_summary(): array {
        $key = defined('DO_SPACES_KEY') ? (string) DO_SPACES_KEY : '';
        return [
            'Bucket' => defined('DO_SPACES_BUCKET') ? (string) DO_SPACES_BUCKET : '',
            'Region' => defined('DO_SPACES_REGION') ? (string) DO_SPACES_REGION : '',
            'Endpoint' => defined('DO_SPACES_ENDPOINT') ? (string) DO_SPACES_ENDPOINT : '',
            'Public URL' => $this->public_base,
            'Prefix' => $this->prefix,
            'Access key' => $key !== '' ? substr($key, 0, 4) . str_repeat('•', 8) : '',
        ];
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
        if (! $key) {
            $this->delete_pending_local_files($post_id, $metadata);
            return;
        }
        if (empty($metadata['file'])) {
            return;
        }

        $dir = dirname($metadata['file']);
        foreach ($this->extra_files($metadata) as [$name]) {
            $this->s3_client()->delete_object($this->object_key_for_relative(($dir === '.' ? '' : $dir . '/') . $name));
        }
    }

    /**
     * WordPress deletes files relative to upload_dir (the staging dir), so media that never reached
     * Spaces would otherwise stay in wp-content/uploads/.
     */
    private function delete_pending_local_files(int $post_id, $metadata): void {
        $relative = $this->attachment_relative_path($post_id);
        if ($relative === '') {
            return;
        }
        $main = $this->local_path_for_relative($relative);
        $dir = dirname($relative);
        $paths = [$main];
        foreach ($this->extra_files($metadata) as [$name]) {
            $paths[] = $this->local_path_for_relative(($dir === '.' ? '' : $dir . '/') . $name);
        }
        foreach ($paths as $path) {
            if (is_file($path)) {
                @unlink($path);
            }
        }
        $this->cleanup_local_upload_path(dirname($main));
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
