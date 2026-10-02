<?php

if (! defined('ABSPATH')) {
    exit;
}

/**
 * Minimal S3-compatible client for DigitalOcean Spaces (Signature V4).
 */
class DO_Spaces_S3 {

    private string $access_key;
    private string $secret_key;
    private string $bucket;
    private string $region;
    private string $endpoint_host;
    private bool $use_path_style;

    public function __construct(
        string $access_key,
        string $secret_key,
        string $bucket,
        string $region,
        string $endpoint,
        bool $use_path_style = false
    ) {
        $this->access_key = $access_key;
        $this->secret_key = $secret_key;
        $this->bucket = $bucket;
        $this->region = $region;
        $this->endpoint_host = (string) wp_parse_url($endpoint, PHP_URL_HOST);
        $this->use_path_style = $use_path_style;
    }

    public function put_file(string $object_key, string $local_path, string $content_type): bool {
        $body = file_get_contents($local_path);
        if ($body === false) {
            return false;
        }

        $response = $this->request('PUT', $object_key, $body, $content_type);
        return ! is_wp_error($response) && wp_remote_retrieve_response_code($response) >= 200
            && wp_remote_retrieve_response_code($response) < 300;
    }

    public function delete_object(string $object_key): bool {
        $response = $this->request('DELETE', $object_key, '', 'application/octet-stream');
        if (is_wp_error($response)) {
            return false;
        }
        $code = wp_remote_retrieve_response_code($response);
        return $code === 204 || $code === 200 || $code === 404;
    }

    public function get_to_file(string $object_key, string $local_path): bool {
        $response = $this->request('GET', $object_key, '', 'application/octet-stream');
        if (is_wp_error($response)) {
            return false;
        }
        $code = wp_remote_retrieve_response_code($response);
        if ($code < 200 || $code >= 300) {
            return false;
        }

        $body = wp_remote_retrieve_body($response);
        if ($body === '') {
            return false;
        }

        $dir = dirname($local_path);
        if (! wp_mkdir_p($dir)) {
            return false;
        }

        return file_put_contents($local_path, $body) !== false;
    }

    private function request(string $method, string $object_key, string $body, string $content_type) {
        $object_key = ltrim($object_key, '/');
        $uri = $this->object_uri($object_key);
        $url = 'https://' . $this->endpoint_host . $uri;
        $payload_hash = hash('sha256', $body);
        $amz_date = gmdate('Ymd\THis\Z');
        $date_stamp = gmdate('Ymd');

        $headers = [
            'host' => $this->endpoint_host,
            'x-amz-content-sha256' => $payload_hash,
            'x-amz-date' => $amz_date,
        ];

        if ($method === 'PUT') {
            $headers['content-type'] = $content_type;
            $headers['content-length'] = (string) strlen($body);
        }

        ksort($headers);
        $canonical_headers = '';
        $signed_header_names = [];
        foreach ($headers as $name => $value) {
            $canonical_headers .= strtolower($name) . ':' . trim($value) . "\n";
            $signed_header_names[] = strtolower($name);
        }
        sort($signed_header_names);
        $signed_headers = implode(';', $signed_header_names);

        $canonical_request = implode("\n", [
            $method,
            $uri,
            '',
            $canonical_headers,
            $signed_headers,
            $payload_hash,
        ]);

        $credential_scope = $date_stamp . '/' . $this->region . '/s3/aws4_request';
        $string_to_sign = implode("\n", [
            'AWS4-HMAC-SHA256',
            $amz_date,
            $credential_scope,
            hash('sha256', $canonical_request),
        ]);

        $signing_key = $this->signing_key($date_stamp);
        $signature = hash_hmac('sha256', $string_to_sign, $signing_key);
        $authorization = 'AWS4-HMAC-SHA256 Credential=' . $this->access_key . '/' . $credential_scope
            . ', SignedHeaders=' . $signed_headers . ', Signature=' . $signature;

        $request_headers = [
            'Host' => $this->endpoint_host,
            'X-Amz-Content-Sha256' => $payload_hash,
            'X-Amz-Date' => $amz_date,
            'Authorization' => $authorization,
        ];
        if ($method === 'PUT') {
            $request_headers['Content-Type'] = $content_type;
            $request_headers['Content-Length'] = (string) strlen($body);
        }

        return wp_remote_request($url, [
            'method' => $method,
            'headers' => $request_headers,
            'body' => $body,
            'timeout' => 120,
        ]);
    }

    private function object_uri(string $object_key): string {
        $encoded = $this->encode_key(ltrim($object_key, '/'));
        if ($this->use_path_style) {
            return '/' . rawurlencode($this->bucket) . '/' . $encoded;
        }
        return '/' . $encoded;
    }

    private function encode_key(string $object_key): string {
        $parts = explode('/', $object_key);
        return implode('/', array_map('rawurlencode', $parts));
    }

    private function signing_key(string $date_stamp): string {
        $k_date = hash_hmac('sha256', $date_stamp, 'AWS4' . $this->secret_key, true);
        $k_region = hash_hmac('sha256', $this->region, $k_date, true);
        $k_service = hash_hmac('sha256', 's3', $k_region, true);
        return hash_hmac('sha256', 'aws4_request', $k_service, true);
    }
}
