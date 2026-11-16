import 'dart:async';

import '../diagnostics/crash_reporter.dart';

/// Runs an async [task] on request, at most one at a time, coalescing
/// requests: a request while a run is in flight makes exactly one more run
/// after it finishes (so the last change is always picked up).
///
/// Replaces a pattern that re-scheduled a microtask while a run was in
/// flight: that spun the microtask queue forever, the awaited database reply
/// (an event) could never arrive, and the app froze (iOS then killed it).
class CoalescingRunner {
  CoalescingRunner(this.task);

  final Future<void> Function() task;
  bool _scheduled = false;
  bool _running = false;
  bool _again = false;
  bool _closed = false;

  /// Ask for a run. Cheap to call many times in a row.
  void request() {
    if (_closed) return;
    if (_running) {
      _again = true;
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(_run);
  }

  Future<void> _run() async {
    _scheduled = false;
    if (_closed || _running) return;
    _running = true;
    try {
      do {
        _again = false;
        try {
          await task();
        } catch (e, st) {
          // Keep going: a request made during the failed run still gets its
          // follow-up run, so the screen does not stay on stale data.
          CrashReporter.instance?.record('reload_failed', e, st);
        }
      } while (_again && !_closed);
    } finally {
      _running = false;
    }
  }

  void close() => _closed = true;
}
