import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:augustyniak_capture/features/backup/data/member_inflater.dart';
import 'package:augustyniak_capture/features/backup/data/verifying_output_stream.dart';
import 'package:augustyniak_capture/features/backup/domain/capture_archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts what was offered to the bound before forwarding it, so a test can
/// see how much the inflater produced before the first refusal.
class _CountingStream extends OutputStream {
  _CountingStream(this._inner) : super(byteOrder: ByteOrder.littleEndian);

  final OutputStream _inner;
  int offered = 0;

  @override
  int get length => _inner.length;

  @override
  void open() => _inner.open();

  @override
  void closeSync() => _inner.closeSync();

  @override
  bool get isOpen => _inner.isOpen;

  @override
  void clear() => _inner.clear();

  @override
  void flush() => _inner.flush();

  @override
  void writeByte(int value) {
    offered += 1;
    _inner.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    offered += length ?? bytes.length;
    _inner.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    offered += stream.length;
    _inner.writeStream(stream);
  }

  @override
  Uint8List subset(int start, [int? end]) => _inner.subset(start, end);
}

/// 8 MiB: one 1 KiB block of random bytes repeated, so it deflates to a small
/// fraction of its size and the input left unread is a meaningful measure.
Uint8List _payload() {
  final Random random = Random(1);
  final Uint8List block = Uint8List.fromList(
    List<int>.generate(1024, (_) => random.nextInt(256)),
  );
  final BytesBuilder builder = BytesBuilder(copy: false);
  for (int i = 0; i < 8 * 1024; i++) {
    builder.add(block);
  }
  return builder.takeBytes();
}

ArchiveFile _decoded(Uint8List payload, {CompressionType? compression}) {
  final ArchiveFile file = ArchiveFile('a.m4a', payload.length, payload);
  if (compression != null) file.compression = compression;
  final List<int> encoded = ZipEncoder().encode(Archive()..addFile(file));
  return ZipDecoder().decodeBytes(encoded).files.single;
}

ZipFile _zip(ArchiveFile entry) => entry.rawContent! as ZipFile;

void main() {
  test('a member that inflates past its declared size is refused after one '
      'chunk', () {
    final Uint8List payload = _payload();
    final ArchiveFile entry = _decoded(payload);
    expect(_zip(entry).compressionMethod, CompressionType.deflate);
    final InputStream raw = _zip(entry).getStream(decompress: false);
    final int compressedLength = raw.length;
    expect(compressedLength, lessThan(payload.length ~/ 8));

    final OutputMemoryStream memory = OutputMemoryStream();
    final _CountingStream spy = _CountingStream(
      VerifyingOutputStream(memory, name: 'a.m4a', declaredBytes: 100),
    );

    expect(
      () => inflateMember(entry, spy),
      throwsA(isA<ArchiveUnreadableException>()),
    );

    expect(spy.offered, greaterThan(100));
    expect(spy.offered, lessThan(1 << 20));
    expect(memory.length, 0);
    // The line that proves the body was never inflated: the package path reads
    // the whole member before its first write.
    expect(raw.position, lessThan(compressedLength ~/ 2));
  });

  test(
    'a member within its declared size streams to the output and hashes',
    () {
      final Uint8List payload = _payload();
      final ArchiveFile entry = _decoded(payload);
      final InputStream raw = _zip(entry).getStream(decompress: false);
      final int startPosition = raw.position;
      final OutputMemoryStream memory = OutputMemoryStream();
      final VerifyingOutputStream verifying = VerifyingOutputStream(
        memory,
        name: 'a.m4a',
        declaredBytes: payload.length,
      );

      inflateMember(entry, verifying);
      verifying.closeSync();

      expect(memory.getBytes(), payload);
      expect(verifying.digest, sha256.convert(payload).toString());
      expect(raw.position, startPosition);
    },
  );

  test('a stored member goes through writeContent', () {
    final Uint8List payload = Uint8List.fromList(
      List<int>.generate(5000, (int i) => i % 251),
    );
    final ArchiveFile entry = _decoded(
      payload,
      compression: CompressionType.none,
    );
    expect(_zip(entry).compressionMethod, CompressionType.none);
    final OutputMemoryStream memory = OutputMemoryStream();
    final VerifyingOutputStream verifying = VerifyingOutputStream(
      memory,
      name: 'a.m4a',
      declaredBytes: payload.length,
    );

    inflateMember(entry, verifying);
    verifying.closeSync();

    expect(memory.getBytes(), payload);
    expect(verifying.digest, sha256.convert(payload).toString());
  });
}
