import 'dart:io';
import 'dart:typed_data';

import 'package:longnote/core/analytics/analytics.dart';
import 'package:longnote/core/db/app_database.dart';
import 'package:longnote/core/recording/recording_repository.dart';
import 'package:longnote/core/util/clock.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fresh on-disk DB + audio folder in a temp directory per test.
class TestEnv {
  TestEnv._(this.dir, this.db, this.repo, this.analytics, this.clock);

  final Directory dir;
  final AppDatabase db;
  final RecordingRepository repo;
  final Analytics analytics;
  final FakeClock clock;

  KvStore get kv => KvStore(db.db);

  static Future<TestEnv> create() async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('longnote_test_');
    final db = await AppDatabase.open(
        factory: databaseFactoryFfi, path: p.join(dir.path, 'test.db'));
    final clock = FakeClock(DateTime(2026, 11, 15, 10, 0, 0));
    final rec = Directory(p.join(dir.path, 'recordings'))..createSync();
    return TestEnv._(
      dir,
      db,
      RecordingRepository(db.db, RecordingStorage(rec.path)),
      Analytics(db.db, clock: clock),
      clock,
    );
  }

  Future<void> dispose() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// [n] bytes of fake PCM (a ramp, so corruption is detectable).
Uint8List pcm(int n, {int seed = 0}) =>
    Uint8List.fromList(List.generate(n, (i) => (i + seed) & 0xff));
