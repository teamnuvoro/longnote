import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_error.dart';

/// Minimal TUS 1.0 client for Supabase Storage resumable uploads
/// (BACKEND-API 2). Mirrors `tools/e2e/e2e.py: tus_upload`.
///
/// - create: POST with Upload-Length + Upload-Metadata -> 201 + Location
/// - offset: HEAD Location -> Upload-Offset (null when the URL expired)
/// - upload: PATCH 6 MB chunks (Supabase requires exactly 6 MB except the
///   last), from the server's offset. The caller persists the Location, so
///   an upload resumes after a crash or app restart.
class TusUploader {
  TusUploader({
    required this.endpoint,
    required this.anonKey,
    http.Client? client,
    this.chunkSize = defaultChunkSize,
    this.timeout = const Duration(minutes: 5),
  }) : _client = client ?? http.Client();

  static const defaultChunkSize = 6 * 1024 * 1024; // 6,291,456

  final Uri endpoint;
  final String anonKey;
  final http.Client _client;
  final int chunkSize;
  final Duration timeout;

  Map<String, String> _headers(String token) => {
        'Authorization': 'Bearer $token',
        'apikey': anonKey,
        'Tus-Resumable': '1.0.0',
        'x-upsert': 'true',
      };

  static String _b64(String s) => base64.encode(utf8.encode(s));

  /// Starts an upload of [length] bytes to `bucket/objectPath`. Returns the
  /// absolute upload URL.
  Future<String> create({
    required String token,
    required String bucket,
    required String objectPath,
    required int length,
    String contentType = 'audio/mp4',
  }) async {
    final r = await _client
        .post(endpoint, headers: {
          ..._headers(token),
          'Upload-Length': '$length',
          'Upload-Metadata': 'bucketName ${_b64(bucket)},'
              'objectName ${_b64(objectPath)},'
              'contentType ${_b64(contentType)},'
              'cacheControl ${_b64('3600')}',
        })
        .timeout(const Duration(seconds: 60));
    if (r.statusCode != 201) throw _error('create', r);
    final loc = r.headers['location'];
    if (loc == null || loc.isEmpty) {
      throw ApiException('server_error', 'TUS create: no Location header',
          httpStatus: r.statusCode);
    }
    return endpoint.resolve(loc).toString();
  }

  /// Bytes the server already has, or null if the upload URL is gone
  /// (expired after 24 h, or unknown): then [create] a new one.
  Future<int?> offset({required String location, required String token}) async {
    final r = await _client
        .head(Uri.parse(location), headers: _headers(token))
        .timeout(const Duration(seconds: 30));
    if (r.statusCode == 404 || r.statusCode == 410 || r.statusCode == 403) {
      return null;
    }
    if (r.statusCode != 200 && r.statusCode != 204) throw _error('head', r);
    return int.tryParse(r.headers['upload-offset'] ?? '');
  }

  /// Sends [file] from [from] to the end. [token] is called before every
  /// chunk so a long upload picks up a refreshed access token.
  /// [onOffset] reports the server's confirmed offset after each chunk.
  Future<void> upload({
    required String location,
    required File file,
    required int from,
    required Future<String> Function() token,
    void Function(int sent, int total)? onOffset,
  }) async {
    final total = await file.length();
    var off = from;
    final raf = await file.open();
    try {
      while (off < total) {
        final n = (total - off) < chunkSize ? total - off : chunkSize;
        await raf.setPosition(off);
        final chunk = await raf.read(n);
        final r = await _client
            .patch(Uri.parse(location),
                headers: {
                  ..._headers(await token()),
                  'Upload-Offset': '$off',
                  'Content-Type': 'application/offset+octet-stream',
                },
                body: chunk)
            .timeout(timeout);
        if (r.statusCode == 409) {
          // Offset mismatch (an earlier PATCH landed without us seeing the
          // reply): ask the server where it is and continue from there.
          final server = await offset(location: location, token: await token());
          if (server == null) throw TusExpired();
          off = server;
          onOffset?.call(off, total);
          continue;
        }
        if (r.statusCode == 404 || r.statusCode == 410) throw TusExpired();
        if (r.statusCode != 204) throw _error('patch', r);
        off = int.tryParse(r.headers['upload-offset'] ?? '') ?? (off + n);
        onOffset?.call(off, total);
      }
    } finally {
      await raf.close();
    }
  }

  ApiException _error(String step, http.Response r) {
    final code = switch (r.statusCode) {
      401 => 'unauthorized',
      // Storage refuses a new upload when the per-user file limit is
      // reached (BACKEND-API 2: HTTP 400; 403 seen too): not a sign-in
      // problem and not permanent.
      400 || 403 when step == 'create' => 'upload_refused',
      403 => 'unauthorized',
      413 => 'payload_too_large',
      >= 500 => 'server_error',
      _ => 'bad_request',
    };
    return ApiException(code, 'TUS $step: HTTP ${r.statusCode}',
        httpStatus: r.statusCode);
  }
}

/// The upload URL is no longer valid; start a new upload (POST).
class TusExpired implements Exception {
  @override
  String toString() => 'TUS upload URL expired';
}
