import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/audio/segment_writer.dart';
import 'package:longnote/core/audio/wav.dart';
import 'package:longnote/core/config.dart';
import 'package:longnote/core/util/clock.dart';
import 'package:path/path.dart' as p;

import 'helpers/test_env.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('seg_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  int dataSize(String name) => readWavSizes(
          File(p.join(dir.path, name)).readAsBytesSync().sublist(0, 44))!
      .dataSize;

  test('production segment size is 5 minutes of 16 kHz mono PCM16', () {
    expect(AppConfig.segmentBytes, 5 * 60 * 32000);
  });

  test('rotates into exact-size segments, splitting chunks at the boundary',
      () {
    final opened = <int>[];
    final closed = <(int, int)>[];
    final sink = SegmentedWavSink(
      directory: dir.path,
      segmentBytes: 1000,
      onSegmentOpened: (i, _, _) => opened.add(i),
      onSegmentClosed: (i, _, b) => closed.add((i, b)),
    )..open();

    // 2600 bytes in uneven chunks -> 1000 + 1000 + 600.
    sink.add(pcm(700));
    sink.add(pcm(700, seed: 700));
    sink.add(pcm(1200, seed: 1400));
    expect(sink.totalBytes, 2600);
    expect(sink.currentIndex, 2);
    sink.close();

    expect(opened, [0, 1, 2]);
    expect(closed, [(0, 1000), (1, 1000), (2, 600)]);
    expect(dataSize('seg_0000.wav'), 1000);
    expect(dataSize('seg_0001.wav'), 1000);
    expect(dataSize('seg_0002.wav'), 600);

    // Concatenated audio equals the input stream, byte for byte.
    final all = [
      for (final n in ['seg_0000.wav', 'seg_0001.wav', 'seg_0002.wav'])
        ...File(p.join(dir.path, n)).readAsBytesSync().sublist(44)
    ];
    expect(all, [...pcm(700), ...pcm(700, seed: 700), ...pcm(1200, seed: 1400)]);
  });

  test('odd-length chunks never split a sample across files', () {
    final sink = SegmentedWavSink(directory: dir.path, segmentBytes: 10)
      ..open();
    sink.add(pcm(5)); // 4 written, 1 held back
    expect(sink.totalBytes, 4);
    sink.add(pcm(7, seed: 5)); // 1 + 7 = 8 -> 12 total
    expect(sink.totalBytes, 12);
    sink.close();
    expect(dataSize('seg_0000.wav'), 10);
    expect(dataSize('seg_0001.wav'), 2);
  });

  test('flushes header at most every flushInterval (crash loses <= ~1 s)', () {
    final clock = FakeClock(DateTime(2026));
    final sink = SegmentedWavSink(
      directory: dir.path,
      segmentBytes: 1 << 20,
      clock: clock,
      flushInterval: const Duration(seconds: 1),
    )..open();
    sink.add(pcm(3200));
    expect(dataSize('seg_0000.wav'), 0, reason: 'no flush yet');
    clock.advance(const Duration(milliseconds: 1000));
    sink.add(pcm(3200));
    expect(dataSize('seg_0000.wav'), 6400, reason: 'flushed after 1 s');
    clock.advance(const Duration(milliseconds: 300));
    sink.add(pcm(3200));
    expect(dataSize('seg_0000.wav'), 6400, reason: 'no flush within 1 s');
    // A timer tick flushes even without new audio.
    clock.advance(const Duration(seconds: 1));
    sink.maybeFlush();
    expect(dataSize('seg_0000.wav'), 9600);
  });

  test('startIndex continues numbering', () {
    final sink =
        SegmentedWavSink(directory: dir.path, segmentBytes: 100, startIndex: 4)
          ..open();
    sink.add(pcm(150));
    sink.close();
    expect(File(p.join(dir.path, 'seg_0004.wav')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'seg_0005.wav')).existsSync(), isTrue);
  });

  test('segment file names round-trip', () {
    expect(segmentFileName(3), 'seg_0003.wav');
    expect(segmentIndexFromName('seg_0003.wav'), 3);
    expect(segmentIndexFromName('seg_12345.wav'), 12345);
    expect(segmentIndexFromName('notes.txt'), isNull);
  });
}
