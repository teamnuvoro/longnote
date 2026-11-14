import 'dart:io';
import 'dart:typed_data';

/// Minimal PCM WAV (RIFF) support: header writing, crash repair, and reading
/// the data length. Everything here is synchronous on purpose: writes are tiny
/// (32 KB/s) and ordering must be exact for crash safety.
class WavFormat {
  const WavFormat({
    this.sampleRate = 16000,
    this.channels = 1,
    this.bitsPerSample = 16,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  int get blockAlign => channels * (bitsPerSample ~/ 8);
  int get byteRate => sampleRate * blockAlign;
}

const int wavHeaderSize = 44;

/// Builds a 44-byte canonical PCM WAV header for [dataBytes] of audio.
Uint8List buildWavHeader(int dataBytes, [WavFormat f = const WavFormat()]) {
  final b = ByteData(wavHeaderSize);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little); // fmt chunk size
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, f.channels, Endian.little);
  b.setUint32(24, f.sampleRate, Endian.little);
  b.setUint32(28, f.byteRate, Endian.little);
  b.setUint16(32, f.blockAlign, Endian.little);
  b.setUint16(34, f.bitsPerSample, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  return b.buffer.asUint8List();
}

/// Reads the sizes stored in a header. Returns null if the header is not a
/// canonical 44-byte PCM header.
({int riffSize, int dataSize})? readWavSizes(Uint8List header) {
  if (header.length < wavHeaderSize) return null;
  String ascii(int o) => String.fromCharCodes(header.sublist(o, o + 4));
  if (ascii(0) != 'RIFF' || ascii(8) != 'WAVE' || ascii(36) != 'data') {
    return null;
  }
  final b = ByteData.sublistView(header);
  return (
    riffSize: b.getUint32(4, Endian.little),
    dataSize: b.getUint32(40, Endian.little),
  );
}

/// Result of [repairWav].
class WavRepairResult {
  WavRepairResult({
    required this.dataBytes,
    required this.repaired,
    required this.empty,
  });

  /// Audio bytes now described by the header.
  final int dataBytes;

  /// True if the header had to be rewritten.
  final bool repaired;

  /// True if the file had no audio at all (or was shorter than a header).
  final bool empty;
}

/// Makes a WAV whose header was never finalized (app killed mid-recording)
/// valid again: rewrites the RIFF and data sizes from the real file length and
/// drops a trailing partial sample. Safe to run on a healthy file (no-op).
WavRepairResult repairWav(String path, [WavFormat f = const WavFormat()]) {
  final file = File(path);
  if (!file.existsSync()) {
    return WavRepairResult(dataBytes: 0, repaired: false, empty: true);
  }
  final raf = file.openSync(mode: FileMode.append);
  try {
    final length = raf.lengthSync();
    if (length < wavHeaderSize) {
      // Header itself is incomplete: there is no audio. Write a valid empty
      // header so players don't choke.
      raf.truncateSync(0);
      raf.setPositionSync(0);
      raf.writeFromSync(buildWavHeader(0, f));
      raf.flushSync();
      return WavRepairResult(dataBytes: 0, repaired: true, empty: true);
    }
    var data = length - wavHeaderSize;
    final aligned = data - (data % f.blockAlign);
    raf.setPositionSync(0);
    final header = raf.readSync(wavHeaderSize);
    final sizes = readWavSizes(header);
    final needsTruncate = aligned != data;
    final headerOk = sizes != null &&
        sizes.dataSize == aligned &&
        sizes.riffSize == 36 + aligned;
    if (headerOk && !needsTruncate) {
      return WavRepairResult(
          dataBytes: aligned, repaired: false, empty: aligned == 0);
    }
    if (needsTruncate) raf.truncateSync(wavHeaderSize + aligned);
    raf.setPositionSync(0);
    raf.writeFromSync(buildWavHeader(aligned, f));
    raf.flushSync();
    data = aligned;
    return WavRepairResult(dataBytes: data, repaired: true, empty: data == 0);
  } finally {
    raf.closeSync();
  }
}

/// Appends PCM to a WAV file and keeps the header roughly current so that a
/// crash leaves a file that is valid up to the last flush.
class WavWriter {
  WavWriter._(this.path, this._raf, this.format);

  final String path;
  final RandomAccessFile _raf;
  final WavFormat format;
  int _dataBytes = 0;
  bool _closed = false;

  int get dataBytes => _dataBytes;
  bool get isClosed => _closed;

  /// Creates (or truncates) [path] and writes an empty header.
  static WavWriter create(String path, [WavFormat f = const WavFormat()]) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final raf = file.openSync(mode: FileMode.write);
    raf.writeFromSync(buildWavHeader(0, f));
    raf.flushSync();
    return WavWriter._(path, raf, f);
  }

  /// Writes PCM bytes straight to the OS (survives an app crash once the call
  /// returns; survives power loss after the next [flush]).
  void append(List<int> pcm) {
    if (_closed) throw StateError('WavWriter closed');
    if (pcm.isEmpty) return;
    _raf.writeFromSync(pcm);
    _dataBytes += pcm.length;
  }

  /// Updates the header sizes and fsyncs.
  void flush() {
    if (_closed) return;
    _writeSizes();
    _raf.flushSync();
  }

  /// Final header + fsync + close.
  void close() {
    if (_closed) return;
    // Keep sample alignment: a stray odd byte would shift every later sample.
    final extra = _dataBytes % format.blockAlign;
    if (extra != 0) {
      _dataBytes -= extra;
      _raf.truncateSync(wavHeaderSize + _dataBytes);
    }
    _writeSizes();
    _raf.flushSync();
    _raf.closeSync();
    _closed = true;
  }

  void _writeSizes() {
    final end = _raf.positionSync();
    final b = ByteData(4);
    _raf.setPositionSync(4);
    b.setUint32(0, 36 + _dataBytes, Endian.little);
    _raf.writeFromSync(b.buffer.asUint8List());
    _raf.setPositionSync(40);
    b.setUint32(0, _dataBytes, Endian.little);
    _raf.writeFromSync(b.buffer.asUint8List());
    _raf.setPositionSync(end);
  }
}

/// Audio bytes in a WAV file, from its length (not trusting the header).
int wavDataBytesFromLength(String path, [WavFormat f = const WavFormat()]) {
  final file = File(path);
  if (!file.existsSync()) return 0;
  final len = file.lengthSync();
  if (len <= wavHeaderSize) return 0;
  final d = len - wavHeaderSize;
  return d - (d % f.blockAlign);
}

/// Concatenates several 16 kHz mono WAV segments into one WAV (streamed, so a
/// 3-hour recording does not need 345 MB of RAM). Used for "share audio".
Future<void> concatWavs(List<String> inputs, String output,
    [WavFormat f = const WavFormat()]) async {
  var total = 0;
  for (final p in inputs) {
    total += wavDataBytesFromLength(p, f);
  }
  final out = File(output).openWrite();
  out.add(buildWavHeader(total, f));
  for (final p in inputs) {
    final n = wavDataBytesFromLength(p, f);
    if (n == 0) continue;
    await out.addStream(File(p).openRead(wavHeaderSize, wavHeaderSize + n));
  }
  await out.flush();
  await out.close();
}
