import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Writes a live PCM stream to a `.wav` file that is **readable at every
/// moment**, which is what lets a live take keep the persist-before-process
/// guarantee.
///
/// The header goes down first with both size fields at `0xFFFFFFFF` ("length
/// unknown", which streaming decoders accept), and every chunk is flushed as it
/// arrives. A crash therefore leaves a playable file with everything up to the
/// last chunk, not an empty one. [close] then patches the two sizes so the
/// finished file is an ordinary WAV.
class WavStreamWriter {
  WavStreamWriter._(this._file, this._raf);

  /// For tests: a writer over a [RandomAccessFile] that can be made to fail.
  @visibleForTesting
  WavStreamWriter.forTesting(this._file, this._raf);

  static const int headerBytes = 44;
  static const int _unknown = 0xFFFFFFFF;

  final File _file;
  final RandomAccessFile _raf;
  Future<void> _tail = Future<void>.value();
  int _dataBytes = 0;
  bool _closed = false;

  File get file => _file;

  /// PCM bytes written so far (the header is not counted).
  int get bytesWritten => _dataBytes;

  /// Creates [file] and writes the open-ended header. 16-bit little-endian PCM.
  static Future<WavStreamWriter> open(
    File file, {
    required int sampleRate,
    int channels = 1,
  }) async {
    final RandomAccessFile raf = await file.open(mode: FileMode.write);
    try {
      final ByteData header = ByteData(headerBytes);
      void tag(int offset, String text) {
        for (int i = 0; i < 4; i++) {
          header.setUint8(offset + i, text.codeUnitAt(i));
        }
      }

      tag(0, 'RIFF');
      header.setUint32(4, _unknown, Endian.little);
      tag(8, 'WAVE');
      tag(12, 'fmt ');
      header.setUint32(16, 16, Endian.little);
      header.setUint16(20, 1, Endian.little);
      header.setUint16(22, channels, Endian.little);
      header.setUint32(24, sampleRate, Endian.little);
      header.setUint32(28, sampleRate * channels * 2, Endian.little);
      header.setUint16(32, channels * 2, Endian.little);
      header.setUint16(34, 16, Endian.little);
      tag(36, 'data');
      header.setUint32(40, _unknown, Endian.little);
      await raf.writeFrom(header.buffer.asUint8List());
      await raf.flush();
      return WavStreamWriter._(file, raf);
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  /// Appends [chunk] and flushes. Calls are serialised, so unawaited writes
  /// from a stream listener land in order. A write after [close] is dropped.
  /// The returned future carries an IO failure: await it or catch it.
  Future<void> write(Uint8List chunk) {
    if (_closed) return Future<void>.value();
    final Future<void> next = _tail.then((_) async {
      await _raf.writeFrom(chunk);
      await _raf.flush();
      // Counted only once it is on disk: the sizes patched into the header at
      // close must describe bytes that exist.
      _dataBytes += chunk.length;
    });
    _tail = next.catchError((Object _) {});
    return next;
  }

  /// Waits for pending writes, patches the RIFF and data sizes, and closes.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _tail;
    try {
      final ByteData sizes = ByteData(4);
      sizes.setUint32(0, headerBytes - 8 + _dataBytes, Endian.little);
      await _raf.setPosition(4);
      await _raf.writeFrom(sizes.buffer.asUint8List());
      sizes.setUint32(0, _dataBytes, Endian.little);
      await _raf.setPosition(40);
      await _raf.writeFrom(sizes.buffer.asUint8List());
      await _raf.flush();
    } finally {
      await _raf.close();
    }
  }
}
