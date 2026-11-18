import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../db/app_database.dart';

/// Meta's 16-field device "extinfo" from the native side (channel
/// "longnote/device", DeviceInfoPlugin in AppDelegate.swift).
abstract class DeviceInfoSource {
  Future<List<String>?> extinfo();
}

class NativeDeviceInfo implements DeviceInfoSource {
  const NativeDeviceInfo([this._ch = const MethodChannel('longnote/device')]);
  final MethodChannel _ch;

  @override
  Future<List<String>?> extinfo() async {
    final l = await _ch.invokeListMethod<Object?>('extinfo');
    if (l == null || l.length != 16) return null;
    return [for (final v in l) v is String ? v : ''];
  }
}

/// No device info (tests, simulator QA, builds without remote analytics).
class NoDeviceInfo implements DeviceInfoSource {
  const NoDeviceInfo();
  @override
  Future<List<String>?> extinfo() async => null;
}

/// Sends the user's "tracking profile" to the backend (`tracking-profile`
/// function, docs/BACKEND-API.md 4.7). The server needs it to send trial /
/// purchase / renewal events from Apple's notifications to Meta and
/// Amplitude for this user, and to know whether it may:
///
/// - `share_analytics`: the Settings switch. Off -> only `{share_analytics:
///   false}` is sent and the server stores nothing else and sends nothing.
/// - `meta_anon_id`: the Meta SDK's anonymous install id (only when Meta is
///   in the build and sharing is on); `att_enabled`: Apple's tracking answer;
/// - app / iOS version, device model, locale and Meta's extinfo array.
/// - `transaction_jws`: StoreKit's Apple-signed current transaction, so the
///   server can link the subscription to this user (a reinstall = a new
///   anonymous user still gets its renewals). The server verifies it.
///
/// [sync] never throws and never blocks the UI (callers do not await it on
/// the UI path). It sends only when the profile differs from the last one
/// the server accepted, and does nothing before the user has a server
/// account (unless [allowSignIn], used right before a purchase). Concurrent
/// calls share one run.
class TrackingProfileSender {
  TrackingProfileSender({
    required this.kv,
    required this.send,
    required this.shareEnabled,
    required this.knownUserId,
    this.metaAnonId,
    this.attAuthorized,
    this.transactionJws,
    this.device = const NoDeviceInfo(),
    this.appVersion,
  });

  final KvStore kv;

  /// POSTs the body to the `tracking-profile` function.
  final Future<void> Function(Map<String, Object?> body) send;
  final Future<bool> Function() shareEnabled;

  /// The stored user id (no network); null before the first sign-in.
  final Future<String?> Function() knownUserId;
  final Future<String?> Function()? metaAnonId;
  final Future<bool> Function()? attAuthorized;
  final Future<String?> Function()? transactionJws;
  final DeviceInfoSource device;
  final String? appVersion;

  /// The last body the server accepted (JSON with the user id), so a
  /// relaunch with nothing changed sends nothing.
  static const kvLastSent = 'tracking_profile_sent';

  Future<bool>? _running;
  bool _again = false;
  bool _againAllowSignIn = false;

  /// Returns true when a profile was sent in this call.
  Future<bool> sync({bool allowSignIn = false}) {
    if (_running != null) {
      // Something changed while a send is running: run once more after it.
      _again = true;
      _againAllowSignIn |= allowSignIn;
      return _running!;
    }
    final run = _sync(allowSignIn).whenComplete(() => _running = null);
    _running = run;
    return run.then((sent) async {
      if (!_again) return sent;
      final s = _againAllowSignIn;
      _again = false;
      _againAllowSignIn = false;
      return await sync(allowSignIn: s) || sent;
    });
  }

  @visibleForTesting
  Future<Map<String, Object?>> buildBody() async {
    if (!await shareEnabled()) return {'share_analytics': false};
    final ext = await _safe(device.extinfo);
    final jws = await _safe(transactionJws);
    String? at(int i) => ext != null && ext[i].isNotEmpty ? ext[i] : null;
    return {
      'share_analytics': true,
      'att_enabled': await _safe(attAuthorized) ?? false,
      'meta_anon_id': ?await _safe(metaAnonId),
      'app_version': ?(appVersion ?? at(2)),
      'os_version': ?at(4),
      'device_model': ?at(5),
      'locale': ?at(6),
      'extinfo': ?ext,
      if (jws != null && jws.length <= 16000) 'transaction_jws': jws,
    };
  }

  Future<bool> _sync(bool allowSignIn) async {
    try {
      if (!allowSignIn && await knownUserId() == null) return false;
      final body = await buildBody();
      // The user id is known after send() (it signs in if needed).
      final before = await knownUserId();
      final key = jsonEncode({'u': before, 'b': body});
      if (before != null && await kv.get(kvLastSent) == key) return false;
      await send(body);
      final after = await knownUserId();
      await kv.set(kvLastSent, jsonEncode({'u': after, 'b': body}));
      return true;
    } catch (e) {
      debugPrint('tracking profile: $e');
      return false;
    }
  }

  static Future<T?> _safe<T>(Future<T?> Function()? f) async {
    if (f == null) return null;
    try {
      return await f().timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
  }
}
