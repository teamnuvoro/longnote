// Simulator QA harness: runs the REAL app (launchApp) with a file-backed
// microphone, records every check as PASS / FAIL / SKIP with screenshots, and
// fails a check on any FlutterError (overflow included), uncaught exception or
// frozen UI. Results go to the HOST folder QA_OUT (simulator apps can write
// host paths), after every check, so a killed run still leaves its results.
//
// Liveness: a 1-second Dart timer writes QA_OUT/heartbeat. A microtask
// livelock (the TestFlight 105 freeze) stops every timer, so the host watcher
// (tools/qa/watcher.py) sees the heartbeat go stale, takes evidence and fails
// the run. Inside the app, each heartbeat also asks for a frame and measures
// how long it takes to arrive (a stuck UI thread = a long wait).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:longnote/app_services.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/features/import/import_controller.dart';
import 'package:longnote/main.dart' show launchApp;
import 'package:longnote/ui/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'file_pcm_source.dart';

const qaOut = String.fromEnvironment('QA_OUT');
const qaRun = String.fromEnvironment('QA_RUN', defaultValue: 'local');
const qaAudio = String.fromEnvironment('QA_AUDIO');

/// A frame that takes longer than this to arrive = the UI froze.
const frozenFrameMs = 5000;

enum Verdict { pass, fail, skip }

class CheckResult {
  CheckResult(this.id, this.title, this.section);
  final String id;
  final String title;
  final String section;
  Verdict verdict = Verdict.skip;
  int ms = 0;
  String? error;
  final notes = <String>[];
  final shots = <String>[];
  final errors = <String>[];
  int maxFrameWaitMs = 0;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'section': section,
        'status': verdict.name.toUpperCase(),
        'ms': ms,
        if (error != null) 'error': error,
        'notes': notes,
        'shots': shots,
        'app_errors': errors,
        'max_frame_wait_ms': maxFrameWaitMs,
      };
}

/// Defines one simulator run (one app launch) as a single test.
void qaRunTest(String description, Future<void> Function(Qa qa) body) {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(description, (tester) async {
    final qa = Qa._(tester, binding);
    await qa._begin();
    final done = Completer<void>();
    runZonedGuarded(() async {
      try {
        await body(qa);
      } catch (e, st) {
        qa._fatal(e, st);
      } finally {
        if (!done.isCompleted) done.complete();
      }
    }, qa._uncaught);
    await done.future;
    await qa._end();
    final bad = qa.results.where((r) => r.verdict == Verdict.fail).toList();
    expect(bad.map((r) => '${r.id} ${r.title}: ${r.error}').toList(), isEmpty,
        reason: 'failed checks (see QA_OUT/results/$qaRun.json)');
  }, timeout: const Timeout(Duration(minutes: 40)));
}

class Qa {
  Qa._(this.tester, this.binding);
  final WidgetTester tester;
  final IntegrationTestWidgetsFlutterBinding binding;
  final results = <CheckResult>[];
  final _appErrors = <Map<String, Object?>>[];
  CheckResult? _current;
  final _started = DateTime.now();
  Timer? _heartbeat;
  FlutterExceptionHandler? _origFlutterOnError;
  bool Function(Object, StackTrace)? _origPlatformOnError;
  int _shotSeq = 0;

  // ---- paths ------------------------------------------------------------------
  static String get outDir => qaOut.isEmpty
      ? p.join(Directory.systemTemp.path, 'qa_out')
      : qaOut;
  static String audio(String name) => p.join(qaAudio, name);
  String get _resultsFile => p.join(outDir, 'results', '$qaRun.json');

  // ---- life cycle ---------------------------------------------------------------
  Future<void> _begin() async {
    for (final d in ['results', 'shots/$qaRun', 'requests']) {
      Directory(p.join(outDir, d)).createSync(recursive: true);
    }
    tester.binding.testTextInput.register();
    _origFlutterOnError = FlutterError.onError;
    _origPlatformOnError = PlatformDispatcher.instance.onError;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) => _beat());
    _beat();
    _write();
    log('run $qaRun started');
  }

  Future<void> _end() async {
    _beat(state: 'finished');
    _heartbeat?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    FlutterError.onError = _origFlutterOnError;
    PlatformDispatcher.instance.onError = _origPlatformOnError;
    tester.binding.testTextInput.unregister();
    _write(finished: true);
    log('run $qaRun finished: ${summaryLine()}');
  }

  String summaryLine() {
    int n(Verdict v) => results.where((r) => r.verdict == v).length;
    return '${n(Verdict.pass)} pass, ${n(Verdict.fail)} fail, ${n(Verdict.skip)} skip';
  }

  /// Launches the real app (main.dart) with the file microphone.
  Future<void> launch() async {
    await launchApp(sourceFactory: () => FilePcmSource(FilePcmSource.nextPath));
    // The app's crash reporter wrapped the test binding's handlers. Record
    // errors here instead, per check (and print them), so one error fails
    // its check and the run carries on to the next one.
    FlutterError.onError = (d) {
      _appError('flutter_error', d.exceptionAsString(), d.stack,
          context: d.context?.toString());
      FlutterError.dumpErrorToConsole(d, forceReport: true);
    };
    PlatformDispatcher.instance.onError = (e, st) {
      _appError('uncaught', e.toString(), st);
      return true;
    };
    await waitFor(find.byType(Navigator), what: 'the app to start');
    await wait(const Duration(seconds: 1));
  }

  // ---- errors -------------------------------------------------------------------
  void _appError(String kind, String text, StackTrace? st, {String? context}) {
    final c = _current;
    final line = '$kind: ${_cut(text, 600)}${context == null ? '' : ' ($context)'}';
    _appErrors.add({
      'check': c?.id,
      'kind': kind,
      'text': _cut(text, 2000),
      'context': ?context,
      'stack': _cut(st?.toString() ?? '', 4000),
    });
    c?.errors.add(line);
    log('APP ERROR during ${c?.id}: $line');
    _write();
  }

  void _uncaught(Object e, StackTrace st) =>
      _appError('uncaught_zone', e.toString(), st);

  void _fatal(Object e, StackTrace st) {
    _appError('harness', e.toString(), st);
    final c = CheckResult('RUN', 'Run finished without a harness error', 'Run')
      ..verdict = Verdict.fail
      ..error = _cut(e.toString(), 800);
    results.add(c);
  }

  static String _cut(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  // ---- liveness ----------------------------------------------------------------
  int? _probeStartedUs;
  int _lastFrameWaitMs = 0;

  void _beat({String state = 'running'}) {
    try {
      File(p.join(outDir, 'heartbeat')).writeAsStringSync(jsonEncode({
        'run': qaRun,
        'state': state,
        'check': _current?.id,
        'at': DateTime.now().millisecondsSinceEpoch,
        'last_frame_wait_ms': _lastFrameWaitMs,
      }));
    } catch (_) {}
    // Frame probe: ask for a frame, time how long it takes to arrive.
    if (_probeStartedUs == null && state == 'running') {
      _probeStartedUs = DateTime.now().microsecondsSinceEpoch;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        final t0 = _probeStartedUs;
        _probeStartedUs = null;
        if (t0 == null) return;
        _frameWait(((DateTime.now().microsecondsSinceEpoch - t0) / 1000).round());
      });
      SchedulerBinding.instance.scheduleFrame();
    } else if (_probeStartedUs != null) {
      final waiting =
          ((DateTime.now().microsecondsSinceEpoch - _probeStartedUs!) / 1000).round();
      if (waiting > frozenFrameMs) _frameWait(waiting, stillWaiting: true);
    }
  }

  void _frameWait(int ms, {bool stillWaiting = false}) {
    _lastFrameWaitMs = ms;
    final c = _current;
    if (c == null) return;
    if (ms > c.maxFrameWaitMs) c.maxFrameWaitMs = ms;
    if (ms > frozenFrameMs && !stillWaiting) {
      c.errors.add('frozen: no frame for ${ms ~/ 1000} s');
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    final c = _current;
    if (c == null) return;
    for (final t in timings) {
      final ms = t.totalSpan.inMilliseconds;
      if (ms > c.maxFrameWaitMs) c.maxFrameWaitMs = ms;
      if (ms > frozenFrameMs) c.errors.add('frozen: one frame took $ms ms');
    }
  }

  // ---- checks -------------------------------------------------------------------
  CheckResult? result(String id) {
    for (final r in results) {
      if (r.id == id) return r;
    }
    return null;
  }

  bool passed(String id) => result(id)?.verdict == Verdict.pass;

  /// Runs one check. [needs]: ids that must have passed (else SKIP).
  Future<bool> check(String id, String title, Future<void> Function() body,
      {required String section,
      List<String> needs = const [],
      Duration timeout = const Duration(minutes: 3),
      bool shotAtEnd = true}) async {
    final r = CheckResult(id, title, section);
    results.add(r);
    final missing = needs.where((n) => !passed(n)).toList();
    if (missing.isNotEmpty) {
      r.verdict = Verdict.skip;
      r.error = 'skipped: needs ${missing.join(', ')} to pass first';
      log('SKIP $id $title (${r.error})');
      _write();
      return false;
    }
    _current = r;
    log('START $id $title');
    final sw = Stopwatch()..start();
    _beat();
    try {
      await body().timeout(timeout,
          onTimeout: () => throw TimeoutException(
              'check did not finish in ${timeout.inSeconds} s'));
      r.verdict = Verdict.pass;
    } catch (e, st) {
      r.verdict = Verdict.fail;
      r.error = _cut(e is TestFailure ? (e.message ?? '$e') : '$e', 1500);
      log('FAIL $id: ${r.error}\n${_cut(st.toString(), 1500)}');
    }
    // Let late errors from this step show up before judging it.
    await wait(const Duration(milliseconds: 400));
    if (r.errors.isNotEmpty && r.verdict == Verdict.pass) {
      r.verdict = Verdict.fail;
      r.error = 'app error(s): ${r.errors.first}'
          '${r.errors.length > 1 ? ' (+${r.errors.length - 1} more)' : ''}';
    }
    r.ms = sw.elapsedMilliseconds;
    if (shotAtEnd || r.verdict == Verdict.fail) {
      await shot(r.verdict == Verdict.fail ? 'FAILED' : 'end');
    }
    log('${r.verdict.name.toUpperCase()} $id $title (${r.ms} ms)');
    _current = null;
    _write();
    return r.verdict == Verdict.pass;
  }

  /// Adds a line to the current check (shown in the report).
  void note(String s) {
    _current?.notes.add(s);
    log('  note: $s');
  }

  void log(String s) {
    final t = DateTime.now().difference(_started).inMilliseconds / 1000;
    // ignore: avoid_print
    print('[QA $qaRun +${t.toStringAsFixed(1)}s] $s');
  }

  void _write({bool finished = false}) {
    try {
      final f = File(_resultsFile);
      f.writeAsStringSync(const JsonEncoder.withIndent(' ').convert({
        'run': qaRun,
        'started': _started.toIso8601String(),
        'updated': DateTime.now().toIso8601String(),
        'finished': finished,
        'checks': [for (final r in results) r.toJson()],
        'app_errors': _appErrors,
        'audio_seconds_sent':
            (FilePcmSource.audioBytesSent / 32000).toStringAsFixed(1),
      }));
    } catch (e) {
      log('could not write results: $e');
    }
  }

  /// Screenshot of the app (iOS draws every visible window) into
  /// `QA_OUT/shots/<run>/`.
  Future<void> shot(String name) async {
    final c = _current;
    final file =
        '${(++_shotSeq).toString().padLeft(2, '0')}-${c?.id ?? 'run'}-$name.png'
            .replaceAll(RegExp(r'[^\w\-.]'), '_');
    try {
      await tester.pump();
      final bytes = await binding
          .takeScreenshot(file)
          .timeout(const Duration(seconds: 15));
      // Keep the driver's final report small: the PNG is on disk already.
      (binding.reportData?['screenshots'] as List?)?.clear();
      File(p.join(outDir, 'shots', qaRun, file)).writeAsBytesSync(bytes);
      c?.shots.add('$qaRun/$file');
    } catch (e) {
      log('screenshot $file failed: $e');
    }
  }

  /// Asks the host watcher to do something (block / unblock the backend)
  /// and waits until it is done.
  Future<void> hostRequest(String what,
      {Duration timeout = const Duration(seconds: 60)}) async {
    final req = File(p.join(outDir, 'requests', what));
    final done = File(p.join(outDir, 'requests', '$what.done'));
    if (done.existsSync()) done.deleteSync();
    req.writeAsStringSync(DateTime.now().toIso8601String());
    final end = DateTime.now().add(timeout);
    while (!done.existsSync()) {
      if (DateTime.now().isAfter(end)) {
        throw TimeoutException('host did not do "$what" in ${timeout.inSeconds} s');
      }
      await wait(const Duration(milliseconds: 500));
    }
    note('host: ${done.readAsStringSync().trim()}');
  }

  /// Ends this run like a force-quit from the app switcher: iOS sends
  /// SIGKILL, nothing runs after it.
  Future<Never> forceQuit() async {
    _beat(state: 'killing');
    _heartbeat?.cancel();
    _write(finished: true);
    log('force-quitting the app (SIGKILL)');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    Process.killPid(pid, ProcessSignal.sigkill);
    await Future<void>.delayed(const Duration(seconds: 5));
    exit(137);
  }

  // ---- driving the UI --------------------------------------------------------
  AppServices get services => Provider.of<AppServices>(
      tester.element(find.byType(Navigator).first),
      listen: false);

  /// Real time passes, frames keep coming.
  Future<void> wait(Duration d) async {
    final end = DateTime.now().add(d);
    do {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    } while (DateTime.now().isBefore(end));
  }

  Future<Finder> waitFor(Finder f,
      {Duration timeout = const Duration(seconds: 15), String? what}) async {
    final end = DateTime.now().add(timeout);
    while (f.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) {
        throw TestFailure(
            'waited ${timeout.inSeconds} s for ${what ?? f.describeMatch(Plurality.one)}');
      }
      await wait(const Duration(milliseconds: 200));
    }
    return f;
  }

  Future<void> waitGone(Finder f,
      {Duration timeout = const Duration(seconds: 15), String? what}) async {
    final end = DateTime.now().add(timeout);
    while (f.evaluate().isNotEmpty) {
      if (DateTime.now().isAfter(end)) {
        throw TestFailure('waited ${timeout.inSeconds} s for ${what ?? f} to go');
      }
      await wait(const Duration(milliseconds: 200));
    }
  }

  Future<void> waitUntil(Future<bool> Function() cond,
      {Duration timeout = const Duration(seconds: 30),
      required String what,
      Duration every = const Duration(milliseconds: 300)}) async {
    final end = DateTime.now().add(timeout);
    while (!await cond()) {
      if (DateTime.now().isAfter(end)) {
        throw TestFailure('waited ${timeout.inSeconds} s for $what');
      }
      await wait(every);
    }
  }

  /// Taps the first hit-testable match (scrolling it into view if needed).
  Future<void> tap(Finder f,
      {Duration after = const Duration(milliseconds: 700), String? what}) async {
    await waitFor(f, what: what);
    var target = f.hitTestable();
    if (target.evaluate().isEmpty) {
      await tester.ensureVisible(f.first);
      await wait(const Duration(milliseconds: 400));
      target = f.hitTestable();
    }
    if (target.evaluate().isEmpty) {
      throw TestFailure('${what ?? f.describeMatch(Plurality.one)} is on screen but not tappable');
    }
    await tester.tap(target.first);
    await wait(after);
  }

  /// Scrolls [within]'s list until [f] is built and on screen (long lists
  /// build their rows lazily).
  Future<void> scrollTo(Finder f, {required Finder within}) async {
    if (f.evaluate().isEmpty) {
      await tester.scrollUntilVisible(f, 250,
          scrollable: find
              .descendant(of: within, matching: find.byType(Scrollable))
              .first,
          maxScrolls: 30);
    }
    await tester.ensureVisible(f.first);
    await wait(const Duration(milliseconds: 400));
  }

  Future<void> type(Finder field, String text) async {
    await waitFor(field);
    await tester.enterText(field.first, text);
    await wait(const Duration(milliseconds: 300));
  }

  /// True when the newest [T] is on the top route.
  bool onTop<T>() {
    final f = find.byType(T);
    if (f.evaluate().isEmpty) return false;
    return ModalRoute.of(f.evaluate().last)?.isCurrent ?? false;
  }

  Future<void> expectOnTop<T>({Duration timeout = const Duration(seconds: 8)}) async {
    final end = DateTime.now().add(timeout);
    while (!onTop<T>()) {
      if (DateTime.now().isAfter(end)) {
        throw TestFailure('expected $T on top within ${timeout.inSeconds} s');
      }
      await wait(const Duration(milliseconds: 150));
    }
  }

  int count<T>() => find.byType(T).evaluate().length;

  /// Back to the Notes tab from wherever the last check left the app (a
  /// failed check may leave a screen or sheet open).
  Future<void> home() async {
    for (var i = 0; i < 6; i++) {
      if (find.byType(LnTabBar).hitTestable().evaluate().isNotEmpty) break;
      try {
        await back();
      } catch (_) {
        await tester.binding.handlePopRoute();
        await wait(const Duration(milliseconds: 600));
      }
    }
    final notes = byLabel('Notes').hitTestable();
    if (notes.evaluate().isNotEmpty) await tap(notes.first);
  }

  /// A screen's back control.
  Future<void> back() async {
    final nav = find.byKey(const ValueKey('nav-back')).hitTestable();
    if (nav.evaluate().isNotEmpty) return tap(nav.last);
    for (final l in ['Notes', 'Back', 'Settings', 'Close', 'Done', 'Cancel']) {
      final f = byLabel(l).hitTestable();
      if (f.evaluate().isNotEmpty) return tap(f.first);
    }
    throw TestFailure('no back control on screen');
  }

  /// The note the user made last.
  Future<Recording> newestNote() async {
    final all = await services.repo.all();
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all.first;
  }

  /// Waits for [id] to reach [want], logging every status it passes.
  Future<List<ProcessingStatus>> waitForStatus(String id, ProcessingStatus want,
      {Duration timeout = const Duration(minutes: 4),
      Future<void> Function(Recording n)? onTick}) async {
    final seen = <ProcessingStatus>[];
    final end = DateTime.now().add(timeout);
    while (true) {
      final n = await services.repo.get(id);
      if (n == null) throw TestFailure('note $id is gone');
      if (seen.isEmpty || seen.last != n.processingStatus) {
        seen.add(n.processingStatus);
        log('  $id -> ${n.processingStatus.name} ${n.processingProgress ?? ''}');
      }
      if (n.processingStatus == want) return seen;
      if (n.processingStatus == ProcessingStatus.failed && want != ProcessingStatus.failed) {
        throw TestFailure('note failed: ${n.processingError} (${n.errorCode}); '
            'statuses ${seen.map((s) => s.name).join(' > ')}');
      }
      if (DateTime.now().isAfter(end)) {
        throw TestFailure('note did not reach ${want.name} in ${timeout.inSeconds} s; '
            'statuses ${seen.map((s) => s.name).join(' > ')}');
      }
      if (onTick != null) await onTick(n);
      await wait(const Duration(milliseconds: 400));
    }
  }
}

/// A tappable by its accessibility label.
Finder byLabel(String label) => find.byWidgetPredicate((w) =>
    (w is LnPressable && w.semanticLabel == label) ||
    (w is LnToggle && w.semanticLabel == label));

Finder byLabelPrefix(String prefix) => find.byWidgetPredicate(
    (w) => w is LnPressable && (w.semanticLabel ?? '').startsWith(prefix));

/// Files picker stand-in: "picks" a file from the host disk (the iOS
/// document picker is a separate process a test cannot drive). It copies it
/// into the app's temp folder first, like the real picker does.
class HostFilePicker implements MediaPicker {
  HostFilePicker(this.hostPath);
  final String hostPath;
  int picks = 0;

  @override
  Future<PickedMedia?> pickFile() async {
    picks++;
    final src = File(hostPath);
    final tmp = Directory.systemTemp.createTempSync('qa_pick_');
    final copy = src.copySync(p.join(tmp.path, p.basename(hostPath)));
    return PickedMedia(
        path: copy.path, name: p.basename(hostPath), bytes: copy.lengthSync());
  }

  @override
  Future<PickedMedia?> pickVideo() async => null;
}

/// The share sheet stand-in: the share_plus platform channel answers
/// "success" and records what the app handed to iOS (texts, files and their
/// sizes). The native share sheet itself is iOS UI a test cannot close.
class ShareRecorder {
  static const channel = MethodChannel('dev.fluttercommunity.plus/share');
  final calls = <Map<String, Object?>>[];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      final a = Map<String, Object?>.from(call.arguments as Map);
      final files = (a['paths'] as List?)?.cast<String>() ?? const <String>[];
      calls.add({
        'method': call.method,
        'text_chars': (a['text'] as String?)?.length ?? 0,
        'text_head': ((a['text'] as String?) ?? '').split('\n').first,
        'subject': a['subject'],
        'files': [
          for (final f in files)
            {
              'name': p.basename(f),
              'bytes': File(f).existsSync() ? File(f).lengthSync() : -1,
            }
        ],
        'mime': a['mimeTypes'],
      });
      return 'dev.fluttercommunity.plus/share/success';
    });
  }

  void uninstall(WidgetTester tester) => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null);
}

/// Earlier runs normally finished onboarding; if one stopped before that,
/// go through it here (Continue, Continue, Allow microphone, Start free
/// trial, Skip) so this run can still test its own part.
Future<void> passFirstRunIfShown(Qa qa) async {
  await qa.wait(const Duration(seconds: 1));
  if (find.text('Allow microphone').evaluate().isNotEmpty ||
      find.text('Continue').evaluate().isNotEmpty) {
    qa.note('onboarding was showing: going through it first');
    while (find.text('Allow microphone').hitTestable().evaluate().isEmpty &&
        find.text('Continue').hitTestable().evaluate().isNotEmpty) {
      await qa.tap(find.text('Continue'));
    }
    await qa.tap(find.text('Allow microphone'));
  }
  if (find.text('Start free trial').evaluate().isNotEmpty) {
    await qa.tap(find.text('Start free trial'));
    await qa.tap(find.text('Skip — I’ll remember'));
  }
}
