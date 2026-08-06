import 'dart:io';

import 'package:crypto/crypto.dart';

/// Computes the stable fingerprint of a capture's immutable source bytes.
///
/// [File.openRead] keeps memory constant for long recordings and unbounded
/// video uploads. The caller owns failure policy; the capture controller treats
/// a missing hash as reduced deduplication, never as a broken capture.
class SourceContentHasher {
  const SourceContentHasher();

  Future<String> hash(File source) async {
    final Digest digest = await sha256.bind(source.openRead()).first;
    return digest.toString();
  }
}
