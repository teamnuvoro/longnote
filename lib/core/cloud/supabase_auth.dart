import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../db/app_database.dart';
import '../util/clock.dart';
import 'api_error.dart';
import 'backend_config.dart';

class AuthSession {
  AuthSession(
      {required this.accessToken,
      required this.refreshToken,
      required this.expiresAt,
      required this.userId});

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String userId;

  Map<String, Object?> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at': expiresAt.millisecondsSinceEpoch,
        'user_id': userId,
      };

  static AuthSession? tryParse(String? s) {
    if (s == null) return null;
    try {
      final m = jsonDecode(s) as Map<String, Object?>;
      return AuthSession(
        accessToken: m['access_token'] as String,
        refreshToken: m['refresh_token'] as String,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(m['expires_at'] as int),
        userId: m['user_id'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  /// From a GoTrue reply `{access_token, refresh_token, expires_in, user:{id}}`.
  static AuthSession fromGoTrue(Map<String, Object?> m, DateTime now) {
    final user = m['user'];
    return AuthSession(
      accessToken: m['access_token'] as String,
      refreshToken: m['refresh_token'] as String,
      expiresAt: now.add(Duration(seconds: (m['expires_in'] as num?)?.toInt() ?? 3600)),
      userId: (user is Map ? user['id'] : null) as String,
    );
  }
}

/// Hidden anonymous sign-in, once per install (BACKEND-API 1), over plain
/// HTTP (no supabase_flutter: fewer native pods, fully testable).
///
/// The session lives in the local database (app sandbox). Tokens last 1 h;
/// [accessToken] refreshes when less than [refreshMargin] is left, and signs
/// up again if the refresh token is no longer valid.
class SupabaseAuth {
  SupabaseAuth({
    required this.config,
    required this.kv,
    http.Client? client,
    Clock clock = const SystemClock(),
    this.refreshMargin = const Duration(minutes: 5),
    this.timeout = const Duration(seconds: 30),
  })  : _client = client ?? http.Client(),
        _clock = clock;

  final BackendConfig config;
  final KvStore kv;
  final http.Client _client;
  final Clock _clock;
  final Duration refreshMargin;
  final Duration timeout;

  static const kvSession = 'supabase_session';

  AuthSession? _session;
  bool _loaded = false;
  Future<AuthSession>? _inFlight;

  /// Valid user access token (signs in / refreshes as needed).
  Future<String> accessToken() async => (await session()).accessToken;

  Future<String> userId() async => (await session()).userId;

  /// Current session, refreshed if it expires within [refreshMargin].
  /// Concurrent callers share one network call.
  Future<AuthSession> session() {
    return _inFlight ??= _ensure().whenComplete(() => _inFlight = null);
  }

  /// Forget the access token (e.g. after a 401) so the next call refreshes.
  Future<void> invalidate() async {
    final s = await _current();
    if (s == null) return;
    _session = AuthSession(
        accessToken: s.accessToken,
        refreshToken: s.refreshToken,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(0),
        userId: s.userId);
  }

  Future<AuthSession?> _current() async {
    if (!_loaded) {
      _session = AuthSession.tryParse(await kv.get(kvSession));
      _loaded = true;
    }
    return _session;
  }

  Future<AuthSession> _ensure() async {
    final s = await _current();
    final now = _clock.now();
    if (s != null && s.expiresAt.difference(now) > refreshMargin) return s;
    if (s != null) {
      final r = await _refresh(s.refreshToken);
      if (r != null) return _store(r);
    }
    return _store(await _signUp());
  }

  Future<AuthSession> _store(AuthSession s) async {
    _session = s;
    await kv.set(kvSession, jsonEncode(s.toJson()));
    return s;
  }

  Map<String, String> get _headers =>
      {'apikey': config.anonKey, 'Content-Type': 'application/json'};

  Future<AuthSession> _signUp() async {
    final r = await _client
        .post(config.authSignUp, headers: _headers, body: '{}')
        .timeout(timeout);
    if (r.statusCode != 200) {
      throw ApiException(
          r.statusCode == 429 ? 'limit_reached' : 'unauthorized',
          'anonymous sign-in failed',
          httpStatus: r.statusCode,
          detail: r.statusCode == 429 ? const {'scope': 'user_hour'} : const {});
    }
    return AuthSession.fromGoTrue(
        jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, Object?>,
        _clock.now());
  }

  /// Null when the refresh token was rejected (then we sign up again).
  Future<AuthSession?> _refresh(String refreshToken) async {
    final r = await _client
        .post(config.authRefresh,
            headers: _headers, body: jsonEncode({'refresh_token': refreshToken}))
        .timeout(timeout);
    if (r.statusCode == 200) {
      return AuthSession.fromGoTrue(
          jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, Object?>,
          _clock.now());
    }
    if (r.statusCode == 400 || r.statusCode == 401 || r.statusCode == 403) {
      return null;
    }
    throw ApiException('server_error', 'token refresh failed',
        httpStatus: r.statusCode);
  }
}
