import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/diagnostics/crash_reporter.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('diag'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('saves Dart errors and MetricKit files, uploads, then deletes', () async {
    final r = CrashReporter(dir: dir, appInfo: {'build': 106});
    r.breadcrumb('route /notes');
    r.record('uncaught', StateError('boom'), StackTrace.current);
    File('${dir.path}/mx-1.json').writeAsStringSync('{"crashDiagnostics":[]}');
    final got = <Map<String, Object?>>[];
    r.send = (m) async => got.add(m);
    expect(await r.uploadPending(), 2);
    expect(got.map((m) => m['kind']), containsAll(['uncaught', 'metrickit']));
    final dart = got.firstWhere((m) => m['kind'] == 'uncaught');
    expect(dart['message'], contains('boom'));
    expect((dart['breadcrumbs'] as List).single, contains('route /notes'));
    expect(dart['app'], {'build': 106});
    expect(dir.listSync(), isEmpty);
  });

  test('keeps reports when the upload fails', () async {
    final r = CrashReporter(dir: dir, appInfo: const {});
    r.record('uncaught', Exception('x'), null);
    r.send = (_) async => throw const SocketException('offline');
    expect(await r.uploadPending(), 0);
    expect(dir.listSync(), hasLength(1));
  });

  test('withholds messages that can contain note text', () async {
    final r = CrashReporter(dir: dir, appInfo: const {});
    r.record('uncaught', const FormatException('secret transcript words'), null);
    final got = <Map<String, Object?>>[];
    r.send = (m) async => got.add(m);
    await r.uploadPending();
    expect(got.single['message'], isNot(contains('secret')));
    expect(got.single['error_type'], 'FormatException');
  });
}
