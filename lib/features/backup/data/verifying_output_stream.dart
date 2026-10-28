import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import '../domain/capture_archive.dart';

/// An [OutputStream] that bounds what a zip member may write and hashes it in
/// the same pass (#311).
///
/// The size a zip member declares and the size the manifest declares are both
/// the archive's own word, and a crafted member can inflate to far more than
/// either. Counting as it writes and refusing the chunk that crosses the
/// declared size is what stops such a member filling the disk; hashing in that
/// same pass avoids re-reading a multi-gigabyte video afterwards.
///
/// On `dart:io` the package's own zlib path inflates the whole member in
/// memory before the first write, so a deflated member is fed through
/// `inflateMember` instead and each chunk reaches this bound as it is produced
/// (#342). The pure-Dart inflater, which a build without `dart:io` falls back
/// to, swallows exceptions thrown from inside its output calls, so a refusal
/// is also recorded in [overflowed] for the caller to check once the write
/// returns.
class VerifyingOutputStream extends OutputStream {
  VerifyingOutputStream(
    this._inner, {
    required String name,
    required int declaredBytes,
  }) : _name = name,
       _declaredBytes = declaredBytes,
       super(byteOrder: ByteOrder.littleEndian) {
    _sink = sha256.startChunkedConversion(_digestSink);
  }

  final OutputStream _inner;
  final String _name;
  final int _declaredBytes;
  final _DigestCapture _digestSink = _DigestCapture();
  late final ByteConversionSink _sink;
  int _written = 0;
  bool _closed = false;

  /// True once a write crossed the declared size and was refused.
  bool overflowed = false;

  /// Hex sha256 of everything written. Valid after [closeSync].
  String get digest => _digestSink.value!.toString();

  @override
  int get length => _written;

  @override
  void open() => _inner.open();

  @override
  void closeSync() {
    if (!_closed) {
      _closed = true;
      _sink.close();
    }
    _inner.closeSync();
  }

  @override
  bool get isOpen => _inner.isOpen;

  @override
  void clear() => _inner.clear();

  @override
  void flush() => _inner.flush();

  @override
  void writeByte(int value) => writeBytes(<int>[value]);

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final int count = length ?? bytes.length;
    if (_written + count > _declaredBytes) {
      overflowed = true;
      throw ArchiveUnreadableException(
        _name,
        'more bytes than the declared $_declaredBytes',
      );
    }
    final List<int> chunk = count == bytes.length
        ? bytes
        : bytes.sublist(0, count);
    _written += count;
    _sink.add(chunk);
    _inner.writeBytes(chunk);
  }

  @override
  void writeStream(InputStream stream) {
    const int chunkSize = 1024 * 1024;
    int remaining = stream.length;
    while (remaining > 0) {
      final int take = remaining > chunkSize ? chunkSize : remaining;
      writeBytes(stream.readBytes(take).toUint8List());
      remaining -= take;
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _inner.subset(start, end);
}

class _DigestCapture implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
