import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:augustyniak_capture/features/backup/data/verifying_output_stream.dart';
import 'package:augustyniak_capture/features/backup/domain/capture_archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bytes within the bound land in the inner stream and are hashed', () {
    final OutputMemoryStream inner = OutputMemoryStream();
    final VerifyingOutputStream stream = VerifyingOutputStream(
      inner,
      name: 'a.m4a',
      declaredBytes: 10,
    );
    final List<int> bytes = <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    stream.writeByte(bytes[0]);
    stream.writeBytes(bytes.sublist(1));
    stream.closeSync();

    expect(stream.length, 10);
    expect(inner.getBytes(), bytes);
    expect(stream.digest, sha256.convert(bytes).toString());
  });

  test('a write that crosses the declared size is refused whole', () {
    final OutputMemoryStream inner = OutputMemoryStream();
    final VerifyingOutputStream stream = VerifyingOutputStream(
      inner,
      name: 'a.m4a',
      declaredBytes: 4,
    );
    stream.writeBytes(<int>[1, 2, 3]);

    expect(
      () => stream.writeBytes(<int>[4, 5, 6]),
      throwsA(
        isA<ArchiveUnreadableException>().having(
          (ArchiveUnreadableException e) => e.reason,
          'reason',
          contains('declared'),
        ),
      ),
    );
    expect(stream.overflowed, isTrue);
    expect(inner.length, lessThanOrEqualTo(4));
    expect(inner.length, 3);
  });

  test('writeStream goes through the same bound', () {
    final OutputMemoryStream inner = OutputMemoryStream();
    final VerifyingOutputStream stream = VerifyingOutputStream(
      inner,
      name: 'a.m4a',
      declaredBytes: 4,
    );

    expect(
      () => stream.writeStream(InputMemoryStream(Uint8List(8))),
      throwsA(isA<ArchiveUnreadableException>()),
    );
    expect(inner.length, 0);
  });
}
