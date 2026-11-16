import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Sends crash and error reports to our server so we can fix what testers
/// hit. Two sources, both saved on the phone first and uploaded later (a
/// crashing app cannot upload):
/// - Dart errors (FlutterError.onError, PlatformDispatcher.onError), with the
///   last screens/steps as breadcrumbs.
/// - iOS MetricKit diagnostics (crashes, hangs, CPU/disk exceptions), written
///   as JSON files by AppDelegate.swift into the same folder; iOS delivers
///   them on the next launch.
///
/// Never includes transcript, summary or recording text: only error types,
/// short messages, stack traces and screen names.
class CrashReporter {
  CrashReporter({required this.dir, required this.appInfo});

  /// `<Application Support>/diagnostics`.
  final Directory dir;

  /// Build/OS info added to every report.
  final Map<String, Object?> appInfo;

  /// Sends one report; throws on failure (the file is kept for next time).
  Future<void> Function(Map<String, Object?> report)? send;

  static CrashReporter? instance;

  static const maxPending = 40;
  static const maxMessage = 2000;
  static const maxStack = 12000;
  static const maxMx = 200000;

  final _crumbs = <String>[];

  /// Last screens / pipeline steps (no user content).
  void breadcrumb(String s) {
    final t = DateTime.now().toUtc().toIso8601String().substring(11, 19);
    _crumbs.add('$t $s');
    if (_crumbs.length > 30) _crumbs.removeAt(0);
  }

  void install() {
    instance = this;
    dir.createSync(recursive: true);
    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      record('flutter_error', details.exception, details.stack,
          context: details.context?.toString());
      prevFlutter?.call(details);
    };
    final prevPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (e, st) {
      record('uncaught', e, st);
      return prevPlatform?.call(e, st) ?? true;
    };
  }

  int _seq = 0;

  void record(String kind, Object error, StackTrace? stack, {String? context}) {
    try {
      final files = _files('dart-');
      if (files.length >= maxPending) return;
      final report = {
        'kind': kind,
        'at': DateTime.now().toUtc().toIso8601String(),
        'error_type': error.runtimeType.toString(),
        'message': _cut(error.toString(), maxMessage),
        if (context != null) 'context': _cut(context, 500),
        'stack': _cut(stack?.toString() ?? '', maxStack),
        'breadcrumbs': List.of(_crumbs),
      };
      final f = File(p.join(dir.path,
          'dart-${DateTime.now().microsecondsSinceEpoch}-${_seq++}.json'));
      f.writeAsStringSync(jsonEncode(report), flush: true);
    } catch (_) {
      // Reporting must never cause a second failure.
    }
  }

  bool _uploading = false;

  /// Uploads every saved report; deletes each one once the server has it.
  Future<int> uploadPending() async {
    final s = send;
    if (s == null || _uploading) return 0;
    _uploading = true;
    var sent = 0;
    try {
      final files = [..._files('dart-'), ..._files('mx-')]
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        Map<String, Object?> body;
        try {
          final text = await f.readAsString();
          final isMx = p.basename(f.path).startsWith('mx-');
          body = isMx
              ? {
                  'kind': 'metrickit',
                  'payload': _cut(text, maxMx),
                }
              : (jsonDecode(text) as Map).cast<String, Object?>();
        } catch (_) {
          await _delete(f); // unreadable: drop it
          continue;
        }
        try {
          await s({...body, 'app': appInfo});
        } catch (_) {
          break; // offline or server down: try again next launch
        }
        await _delete(f);
        sent++;
      }
    } finally {
      _uploading = false;
    }
    return sent;
  }

  List<File> _files(String prefix) {
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) =>
            p.basename(f.path).startsWith(prefix) && f.path.endsWith('.json'))
        .toList();
  }

  static Future<void> _delete(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }

  static String _cut(String s, int n) => s.length <= n ? s : s.substring(0, n);
}
