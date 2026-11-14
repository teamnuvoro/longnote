import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/audio/wav.dart';
import 'package:path/path.dart' as p;

import 'helpers/test_env.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('wav_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Uint8List header(String path) =>
      File(path).readAsBytesSync().sublist(0, wavHeaderSize);

  test('header has correct RIFF/fmt/data fields for 16 kHz mono PCM16', () {
    final h = buildWavHeader(32000);
    final b = ByteData.sublistView(h);
    expect(String.fromCharCodes(h.sublist(0, 4)), 'RIFF');
    expect(b.getUint32(4, Endian.little), 36 + 32000);
    expect(String.fromCharCodes(h.sublist(8, 12)), 'WAVE');
    expect(b.getUint16(20, Endian.little), 1); // PCM
    expect(b.getUint16(22, Endian.little), 1); // mono
    expect(b.getUint32(24, Endian.little), 16000);
    expect(b.getUint32(28, Endian.little), 32000); // byte rate
    expect(b.getUint16(32, Endian.little), 2); // block align
    expect(b.getUint16(34, Endian.little), 16);
    expect(b.getUint32(40, Endian.little), 32000);
    expect(readWavSizes(h), (riffSize: 36 + 32000, dataSize: 32000));
  });

  test('writer keeps header current on flush and final on close', () {
    final path = p.join(dir.path, 'a.wav');
    final w = WavWriter.create(path);
    w.append(pcm(1000));
    // Before flush the header still says 0 (this is the crash case).
    expect(readWavSizes(header(path))!.dataSize, 0);
    w.flush();
    expect(readWavSizes(header(path))!.dataSize, 1000);
    w.append(pcm(500));
    w.close();
    expect(readWavSizes(header(path))!.dataSize, 1500);
    expect(File(path).lengthSync(), wavHeaderSize + 1500);
    // Data intact and in order.
    final data = File(path).readAsBytesSync().sublist(wavHeaderSize);
    expect(data.sublist(0, 1000), pcm(1000));
    expect(data.sublist(1000), pcm(500));
  });

  test('repair fixes a header that was never finalized (app killed)', () {
    final path = p.join(dir.path, 'crash.wav');
    final w = WavWriter.create(path);
    w.append(pcm(64000)); // 2 s of audio, never flushed/closed
    // Simulate the process dying: no close(). Header still says 0.
    expect(readWavSizes(header(path))!.dataSize, 0);

    final r = repairWav(path);
    expect(r.repaired, isTrue);
    expect(r.dataBytes, 64000);
    expect(readWavSizes(header(path)), (riffSize: 36 + 64000, dataSize: 64000));
    // Audio bytes untouched.
    expect(File(path).readAsBytesSync().sublist(wavHeaderSize), pcm(64000));
  });

  test('repair drops a trailing half sample after truncation', () {
    final path = p.join(dir.path, 'odd.wav');
    File(path).writeAsBytesSync([...buildWavHeader(0), ...pcm(1001)]);
    final r = repairWav(path);
    expect(r.dataBytes, 1000);
    expect(File(path).lengthSync(), wavHeaderSize + 1000);
    expect(readWavSizes(header(path))!.dataSize, 1000);
  });

  test('repair handles a header that says more than the file holds', () {
    // Header claims 10 s but the file was cut at 1 s (e.g. partial write).
    final path = p.join(dir.path, 'long.wav');
    File(path).writeAsBytesSync([...buildWavHeader(320000), ...pcm(32000)]);
    final r = repairWav(path);
    expect(r.repaired, isTrue);
    expect(r.dataBytes, 32000);
  });

  test('repair of a file shorter than a header leaves a valid empty WAV', () {
    final path = p.join(dir.path, 'tiny.wav');
    File(path).writeAsBytesSync([82, 73, 70]); // "RIF"
    final r = repairWav(path);
    expect(r.empty, isTrue);
    expect(r.dataBytes, 0);
    expect(File(path).lengthSync(), wavHeaderSize);
    expect(readWavSizes(header(path))!.dataSize, 0);
  });

  test('repair is a no-op on a healthy file', () {
    final path = p.join(dir.path, 'ok.wav');
    final w = WavWriter.create(path)..append(pcm(2000));
    w.close();
    final before = File(path).readAsBytesSync();
    final r = repairWav(path);
    expect(r.repaired, isFalse);
    expect(r.dataBytes, 2000);
    expect(File(path).readAsBytesSync(), before);
  });

  test('repair of a missing file reports empty and creates nothing', () {
    final path = p.join(dir.path, 'missing.wav');
    final r = repairWav(path);
    expect(r.empty, isTrue);
    expect(File(path).existsSync(), isFalse);
  });

  test('concatWavs joins parts into one valid WAV', () async {
    final a = p.join(dir.path, 'a.wav');
    final b = p.join(dir.path, 'b.wav');
    (WavWriter.create(a)..append(pcm(3000))).close();
    (WavWriter.create(b)..append(pcm(1000, seed: 7))).close();
    final out = p.join(dir.path, 'all.wav');
    await concatWavs([a, b], out);
    final bytes = File(out).readAsBytesSync();
    expect(readWavSizes(bytes.sublist(0, 44))!.dataSize, 4000);
    expect(bytes.sublist(44, 3044), pcm(3000));
    expect(bytes.sublist(3044), pcm(1000, seed: 7));
  });
}
