<?php

if (! defined('ABSPATH')) {
    exit;
}

/**
 * Media > DO Spaces: settings check, connection test, and moving existing server uploads to Spaces.
 */
class DO_Spaces_Admin {

    private const PAGE = 'do-spaces';
    private const NONCE = 'do_spaces_admin';
    private const BATCH = 5;
    private const CONNECTION_TRANSIENT = 'do_spaces_connection';
    private const PENDING_TRANSIENT = 'do_spaces_pending_count';
    private const DISMISS_META = 'do_spaces_notice_dismissed';

    private DO_Spaces_Uploads $service;

    public function __construct(DO_Spaces_Uploads $service) {
        $this->service = $service;
        add_action('admin_menu', [$this, 'register_page']);
        add_action('admin_notices', [$this, 'pending_notice']);
        add_action('wp_ajax_do_spaces_test', [$this, 'ajax_test']);
        add_action('wp_ajax_do_spaces_migrate_batch', [$this, 'ajax_migrate_batch']);
        add_action('wp_ajax_do_spaces_dismiss', [$this, 'ajax_dismiss']);
    }

    public function register_page(): void {
        add_media_page('DO Spaces', 'DO Spaces', 'manage_options', self::PAGE, [$this, 'render_page']);
    }

    /** @return array{ok: bool, message: string} */
    private function connection(bool $refresh = false): array {
        $cached = get_transient(self::CONNECTION_TRANSIENT);
        if (! $refresh && is_array($cached)) {
            return $cached;
        }
        $result = $this->service->test_connection();
        set_transient(self::CONNECTION_TRANSIENT, $result, $result['ok'] ? HOUR_IN_SECONDS : 5 * MINUTE_IN_SECONDS);
        return $result;
    }

    private function pending_count(bool $refresh = false): int {
        $cached = get_transient(self::PENDING_TRANSIENT);
        if (! $refresh && $cached !== false) {
            return (int) $cached;
        }
        $count = count($this->service->pending_local_ids());
        set_transient(self::PENDING_TRANSIENT, $count, 10 * MINUTE_IN_SECONDS);
        return $count;
    }

    public function pending_notice(): void {
        if (! current_user_can('manage_options') || ! $this->service->is_enabled()) {
            return;
        }
        $screen = function_exists('get_current_screen') ? get_current_screen() : null;
        if ($screen && $screen->id === 'media_page_' . self::PAGE) {
            return;
        }
        $count = $this->pending_count();
        if ($count === 0 || (int) get_user_meta(get_current_user_id(), self::DISMISS_META, true) === $count) {
            return;
        }
        if (! $this->connection()['ok']) {
            return;
        }
        $url = admin_url('upload.php?page=' . self::PAGE);
        printf(
            '<div class="notice notice-info is-dismissible do-spaces-notice" data-count="%1$d"><p>%2$s <a href="%3$s">%4$s</a></p></div>',
            $count,
            esc_html(sprintf(_n('%d media file is still stored on this server, not in DigitalOcean Spaces.', '%d media files are still stored on this server, not in DigitalOcean Spaces.', $count), $count)),
            esc_url($url),
            esc_html__('Upload them to Spaces')
        );
        $nonce = wp_create_nonce(self::NONCE);
        ?>
        <script>
        document.addEventListener('click', function (event) {
            var notice = event.target.closest('.do-spaces-notice');
            if (!notice || !event.target.classList.contains('notice-dismiss')) { return; }
            var body = new URLSearchParams({action: 'do_spaces_dismiss', _ajax_nonce: <?php echo wp_json_encode($nonce); ?>, count: notice.dataset.count});
            fetch(ajaxurl, {method: 'POST', credentials: 'same-origin', body: body});
        });
        </script>
        <?php
    }

    public function render_page(): void {
        if (! current_user_can('manage_options')) {
            wp_die(esc_html__('Sorry, you are not allowed to access this page.'));
        }

        $enabled = $this->service->is_enabled();
        $connection = $enabled ? $this->connection(isset($_GET['retest'])) : ['ok' => false, 'message' => ''];
        $pending = $this->pending_count(true);
        $nonce = wp_create_nonce(self::NONCE);
        ?>
        <div class="wrap">
            <h1>DigitalOcean Spaces</h1>

            <h2>Status</h2>
            <table class="widefat striped" style="max-width:720px">
                <tbody>
                <tr>
                    <th scope="row">Spaces offload</th>
                    <td><?php echo $enabled ? '<strong style="color:#008a20">Enabled</strong>' : '<strong>Disabled</strong>'; ?></td>
                </tr>
                <?php if ($enabled) : ?>
                    <?php foreach ($this->service->config_summary() as $label => $value) : ?>
                        <tr>
                            <th scope="row"><?php echo esc_html($label); ?></th>
                            <td><code><?php echo esc_html($value !== '' ? $value : '—'); ?></code></td>
                        </tr>
                    <?php endforeach; ?>
                    <tr>
                        <th scope="row">Connection</th>
                        <td>
                            <span id="do-spaces-connection" style="color:<?php echo $connection['ok'] ? '#008a20' : '#d63638'; ?>">
                                <?php echo esc_html(($connection['ok'] ? 'OK: ' : 'Failed: ') . $connection['message']); ?>
                            </span>
                            <button type="button" class="button button-small" id="do-spaces-test" style="margin-left:8px">Test again</button>
                        </td>
                    </tr>
                <?php endif; ?>
                <tr>
                    <th scope="row">Media still on this server</th>
                    <td><strong id="do-spaces-pending"><?php echo (int) $pending; ?></strong> attachment(s) in <code>wp-content/uploads</code> not yet in Spaces</td>
                </tr>
                </tbody>
            </table>

            <?php if (! $enabled) : ?>
                <p>Spaces is turned off for this site. To enable it, set <code>SPACES_ENABLED=yes</code> and the real key, secret, and bucket in <code>sites/&lt;id&gt;.env</code> on the server, then run <code>./wpd env:generate</code> and <code>./wpd up</code>. Settings live in the server config, not in this screen.</p>
            <?php elseif (! $connection['ok']) : ?>
                <p>Fix the connection before uploading. Settings live in <code>sites/&lt;id&gt;.env</code> on the server; after changing them run <code>./wpd env:generate</code> and <code>./wpd up</code>.</p>
            <?php elseif ($pending === 0) : ?>
                <p>Every attachment is in Spaces. New uploads go there automatically.</p>
            <?php else : ?>
                <h2>Upload server media to Spaces</h2>
                <p>Uploads each attachment with its thumbnails and original, a few at a time. An attachment is only switched to Spaces after all of its files uploaded. You can leave this page; anything not yet uploaded stays on the server and can be resumed later.</p>
                <p>
                    <label><input type="checkbox" id="do-spaces-keep-local"> Keep a copy on the server after uploading</label>
                </p>
                <p>
                    <button type="button" class="button button-primary" id="do-spaces-start">Upload <?php echo (int) $pending; ?> attachment(s) to Spaces</button>
                    <button type="button" class="button" id="do-spaces-stop" style="display:none">Stop after this batch</button>
                </p>
                <div id="do-spaces-progress" style="display:none;max-width:720px">
                    <progress id="do-spaces-bar" value="0" max="<?php echo (int) $pending; ?>" style="width:100%"></progress>
                    <p id="do-spaces-summary"></p>
                    <ul id="do-spaces-errors" style="color:#d63638"></ul>
                </div>
                <p class="description">For large libraries, the command line is faster: <code>./wpd spaces:migrate &lt;site&gt;</code>.</p>
            <?php endif; ?>
        </div>
        <script>
        (function () {
            var nonce = <?php echo wp_json_encode($nonce); ?>;
            function post(params) {
                params._ajax_nonce = nonce;
                return fetch(ajaxurl, {method: 'POST', credentials: 'same-origin', body: new URLSearchParams(params)})
                    .then(function (r) { return r.json(); });
            }
            var test = document.getElementById('do-spaces-test');
            if (test) {
                test.addEventListener('click', function () {
                    var out = document.getElementById('do-spaces-connection');
                    out.textContent = 'Testing…';
                    post({action: 'do_spaces_test'}).then(function (res) {
                        var data = res.data || {};
                        out.style.color = data.ok ? '#008a20' : '#d63638';
                        out.textContent = (data.ok ? 'OK: ' : 'Failed: ') + (data.message || 'Unknown error');
                        if (data.ok !== <?php echo wp_json_encode($connection['ok']); ?>) { location.reload(); }
                    });
                });
            }
            var start = document.getElementById('do-spaces-start');
            if (!start) { return; }
            var stop = document.getElementById('do-spaces-stop');
            var stopping = false;
            var initial = <?php echo (int) $pending; ?>;
            var exclude = [];
            var totals = {migrated: 0, failed: 0, missing: 0, skipped: 0};
            stop.addEventListener('click', function () { stopping = true; stop.disabled = true; });
            start.addEventListener('click', function () {
                start.disabled = true;
                stop.style.display = '';
                document.getElementById('do-spaces-keep-local').disabled = true;
                document.getElementById('do-spaces-progress').style.display = '';
                run();
            });
            function summary(text) { document.getElementById('do-spaces-summary').textContent = text; }
            function run() {
                post({
                    action: 'do_spaces_migrate_batch',
                    keep_local: document.getElementById('do-spaces-keep-local').checked ? '1' : '0',
                    exclude: exclude.join(',')
                }).then(function (res) {
                    if (!res.success) { throw new Error((res.data && res.data.message) || 'Request failed'); }
                    var data = res.data;
                    Object.keys(totals).forEach(function (k) { totals[k] += data.counts[k] || 0; });
                    exclude = exclude.concat(data.failed_ids);
                    data.errors.forEach(function (e) {
                        var li = document.createElement('li');
                        li.textContent = e;
                        document.getElementById('do-spaces-errors').appendChild(li);
                    });
                    var bar = document.getElementById('do-spaces-bar');
                    var done = totals.migrated + totals.failed + totals.missing + totals.skipped;
                    var remaining = data.more ? Math.max(initial - done, 0) : 0;
                    bar.value = done;
                    document.getElementById('do-spaces-pending').textContent = remaining + totals.failed;
                    summary('Uploaded ' + totals.migrated + ', failed ' + totals.failed + ', remaining ' + remaining + '.');
                    if (data.more && !stopping) {
                        run();
                    } else {
                        stop.style.display = 'none';
                        summary(document.getElementById('do-spaces-summary').textContent
                            + (stopping ? ' Stopped.' : ' Done.')
                            + (totals.failed ? ' Failed items stay on the server; reload to retry.' : ''));
                    }
                }).catch(function (err) {
                    stop.style.display = 'none';
                    summary('Stopped: ' + err.message + '. Reload the page to resume.');
                });
            }
        })();
        </script>
        <?php
    }

    private function check_ajax(): void {
        if (! current_user_can('manage_options') || ! check_ajax_referer(self::NONCE, false, false)) {
            wp_send_json_error(['message' => 'Not allowed.'], 403);
        }
    }

    public function ajax_test(): void {
        $this->check_ajax();
        wp_send_json_success($this->connection(true));
    }

    public function ajax_migrate_batch(): void {
        $this->check_ajax();
        if (! $this->service->is_enabled() || ! $this->connection()['ok']) {
            wp_send_json_error(['message' => 'Spaces is not enabled or the connection test failed.']);
        }

        $keep_local = isset($_POST['keep_local']) && $_POST['keep_local'] === '1';
        $exclude = isset($_POST['exclude']) && $_POST['exclude'] !== ''
            ? array_filter(array_map('intval', explode(',', sanitize_text_field(wp_unslash($_POST['exclude'])))))
            : [];

        $counts = ['migrated' => 0, 'skipped' => 0, 'missing' => 0, 'failed' => 0];
        $failed_ids = [];
        $errors = [];
        $ids = $this->service->pending_local_ids(self::BATCH, $exclude);
        foreach ($ids as $id) {
            $result = $this->service->migrate_attachment($id, false, ! $keep_local);
            $counts[$result] = ($counts[$result] ?? 0) + 1;
            if ($result === 'failed') {
                $failed_ids[] = $id;
                $errors[] = sprintf('#%d %s: upload failed', $id, $this->service->attachment_relative_path($id));
            }
        }

        delete_transient(self::PENDING_TRANSIENT);

        wp_send_json_success([
            'processed' => count($ids),
            'more' => count($ids) === self::BATCH,
            'counts' => $counts,
            'failed_ids' => $failed_ids,
            'errors' => $errors,
        ]);
    }

    public function ajax_dismiss(): void {
        $this->check_ajax();
        update_user_meta(get_current_user_id(), self::DISMISS_META, isset($_POST['count']) ? (int) $_POST['count'] : 0);
        wp_send_json_success();
    }
}
