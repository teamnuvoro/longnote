import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../util/clock.dart';
import 'wav.dart';

String segmentFileName(int index) =>
    'seg_${index.toString().padLeft(4, '0')}.wav';

/// Parses "seg_0003.wav" -> 3; null for anything else.
int? segmentIndexFromName(String name) {
  final m = RegExp(r'^seg_(\d{4,})\.wav$').firstMatch(name);
  return m == null ? null : int.parse(m.group(1)!);
}

typedef SegmentCallback = void Function(int index, String fileName,
    int dataBytes);

/// Receives the PCM stream and writes it into rotating WAV segments of
/// exactly [segmentBytes] audio bytes each. Writes go to disk on every chunk;
/// header update + fsync happen at least every [flushInterval].
///
/// Pure Dart (no plugins), so it is unit-tested directly.
class SegmentedWavSink {
  SegmentedWavSink({
    required this.directory,
    required this.segmentBytes,
    this.startIndex = 0,
    this.flushInterval = const Duration(seconds: 1),
    Clock? clock,
    this.format = const WavFormat(),
    this.onSegmentOpened,
    this.onSegmentClosed,
  })  : assert(segmentBytes > 0 && segmentBytes % 2 == 0),
        _clock = clock ?? const SystemClock();

  final String directory;
  final int segmentBytes;
  final int startIndex;
  final Duration flushInterval;
  final WavFormat format;
  final Clock _clock;
  final SegmentCallback? onSegmentOpened;
  final SegmentCallback? onSegmentClosed;

  WavWriter? _writer;
  int _index = 0;
  int _totalBytes = 0;
  DateTime? _lastFlush;
  int _pendingOddByte = -1;

  int get currentIndex => _index;
  int get totalBytes => _totalBytes;
  int get currentSegmentBytes => _writer?.dataBytes ?? 0;
  bool get isOpen => _writer != null;
  Duration get totalDuration =>
      Duration(milliseconds: _totalBytes * 1000 ~/ format.byteRate);

  void open() {
    if (_writer != null) return;
    _index = startIndex;
    _openSegment();
  }

  void _openSegment() {
    final name = segmentFileName(_index);
    _writer = WavWriter.create(p.join(directory, name), format);
    _lastFlush = _clock.now();
    onSegmentOpened?.call(_index, name, 0);
  }

  void _closeSegment() {
    final w = _writer;
    if (w == null) return;
    w.close();
    onSegmentClosed?.call(_index, p.basename(w.path), w.dataBytes);
    _writer = null;
  }

  /// Adds PCM16 bytes. Chunks may have odd length (platform buffers); we keep
  /// a byte back so samples are never split across files.
  void add(Uint8List chunk) {
    if (_writer == null) throw StateError('sink not open');
    var data = chunk;
    if (_pendingOddByte >= 0) {
      data = Uint8List(chunk.length + 1)
        ..[0] = _pendingOddByte
        ..setRange(1, chunk.length + 1, chunk);
      _pendingOddByte = -1;
    }
    if (data.length.isOdd) {
      _pendingOddByte = data.last;
      data = Uint8List.sublistView(data, 0, data.length - 1);
    }
    var offset = 0;
    while (offset < data.length) {
      final room = segmentBytes - _writer!.dataBytes;
      final take = (data.length - offset) < room ? data.length - offset : room;
      _writer!.append(Uint8List.sublistView(data, offset, offset + take));
      offset += take;
      _totalBytes += take;
      if (_writer!.dataBytes >= segmentBytes) {
        _closeSegment();
        _index++;
        _openSegment();
      }
    }
    maybeFlush();
  }

  /// Flushes if [flushInterval] has passed. Also call this from a timer so a
  /// silent stream (paused) still gets flushed.
  void maybeFlush() {
    final w = _writer;
    if (w == null) return;
    final now = _clock.now();
    if (_lastFlush == null || now.difference(_lastFlush!) >= flushInterval) {
      w.flush();
      _lastFlush = now;
    }
  }

  void flushNow() {
    _writer?.flush();
    _lastFlush = _clock.now();
  }

  /// Finalizes the open segment. An empty trailing segment (rotation happened
  /// exactly at the end) is kept as a valid empty WAV and reported with 0
  /// bytes so callers can drop it.
  void close() => _closeSegment();
}
