<?php
/**
 * Offline self-check: load the SigV4 client with WP HTTP stubs and assert a PUT is signed.
 * Run: php plugins/do-spaces-uploads/tests/smoke-s3-signing.php
 */

declare(strict_types=1);

define('ABSPATH', __DIR__ . '/');

$GLOBALS['do_spaces_last_request'] = null;

function wp_parse_url(string $url, int $component = -1) {
    return parse_url($url, $component);
}

function is_wp_error($thing): bool {
    return false;
}

/**
 * @param array<string, mixed> $args
 * @return array{response: array{code: int}, body: string}
 */
function wp_remote_request(string $url, array $args = []): array {
    $GLOBALS['do_spaces_last_request'] = ['url' => $url, 'args' => $args];
    return ['response' => ['code' => 200], 'body' => ''];
}

function wp_remote_retrieve_response_code(array $response): int {
    return (int) ($response['response']['code'] ?? 0);
}

function wp_remote_retrieve_body(array $response): string {
    return (string) ($response['body'] ?? '');
}

function wp_mkdir_p(string $dir): bool {
    return is_dir($dir) || mkdir($dir, 0777, true);
}

require dirname(__DIR__) . '/includes/class-do-spaces-s3.php';

$tmp = tempnam(sys_get_temp_dir(), 'do-spaces-smoke');
if ($tmp === false || file_put_contents($tmp, 'ok') === false) {
    fwrite(STDERR, "Could not write temp file.\n");
    exit(1);
}

$client = new DO_Spaces_S3(
    'AKIAEXAMPLEKEY0001',
    'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    'my-bucket',
    'sgp1',
    'https://my-bucket.sgp1.digitaloceanspaces.com',
    false
);

$ok = $client->put_file('prefix/.do-spaces-check-smoke', $tmp, 'text/plain');
@unlink($tmp);

if (! $ok) {
    fwrite(STDERR, "put_file returned false under stubbed HTTP.\n");
    exit(1);
}

$req = $GLOBALS['do_spaces_last_request'];
if (! is_array($req)) {
    fwrite(STDERR, "No HTTP request captured.\n");
    exit(1);
}

$url = $req['url'] ?? '';
$headers = $req['args']['headers'] ?? [];
$method = $req['args']['method'] ?? '';

$errors = [];
if ($method !== 'PUT') {
    $errors[] = "expected PUT, got {$method}";
}
if ($url !== 'https://my-bucket.sgp1.digitaloceanspaces.com/prefix/.do-spaces-check-smoke') {
    $errors[] = "unexpected URL: {$url}";
}
if (! isset($headers['Authorization']) || ! str_starts_with((string) $headers['Authorization'], 'AWS4-HMAC-SHA256 Credential=')) {
    $errors[] = 'missing AWS4 Authorization header';
}
if (! isset($headers['X-Amz-Date']) || ! preg_match('/^\d{8}T\d{6}Z$/', (string) $headers['X-Amz-Date'])) {
    $errors[] = 'missing or invalid X-Amz-Date';
}
if (($headers['Host'] ?? '') !== 'my-bucket.sgp1.digitaloceanspaces.com') {
    $errors[] = 'Host header mismatch';
}

if ($errors !== []) {
    fwrite(STDERR, "SigV4 self-check failed:\n- " . implode("\n- ", $errors) . "\n");
    exit(1);
}

echo "SigV4 PUT shaped correctly for virtual-hosted Spaces endpoint.\n";
exit(0);
