import 'dart:convert';
import 'dart:io' as io;

import 'package:archive/archive_io.dart';

/// Write a zip member to [output] without ever holding its inflated body in
/// memory (#342).
///
/// `ArchiveFile.writeContent` inflates a deflated member in full before the
/// first byte reaches the [OutputStream], so a bound on what the stream will
/// accept (`VerifyingOutputStream`, #311) protected the disk but not RAM. Here
/// the compressed bytes are fed to `dart:io`'s chunked inflater in small
/// slices and every inflated chunk is handed to [output] as it is produced;
/// the throw from a refused chunk stops the inflater at once, with only that
/// one chunk ever materialised. A stored member already streams through
/// `writeStream`, and bzip2 — which this app never writes — keeps the
/// package's path.
void inflateMember(ArchiveFile entry, OutputStream output) {
  final FileContent? raw = entry.rawContent;
  if (raw is! ZipFile || raw.compressionMethod != CompressionType.deflate) {
    entry.writeContent(output);
    return;
  }
  final InputStream compressed = raw.getStream(decompress: false);
  final int start = compressed.position;
  final ByteConversionSink inflater = io.ZLibDecoder(
    raw: true,
  ).startChunkedConversion(_ForwardingSink(output));
  while (!compressed.isEOS) {
    final int take = compressed.length < _feedBytes
        ? compressed.length
        : _feedBytes;
    inflater.add(compressed.readBytes(take).toUint8List());
  }
  inflater.close();
  // Mirrors the package: a member stays readable again after a full pass.
  // On a throw the position is deliberately left where inflation stopped.
  compressed.setPosition(start);
}

/// Compressed bytes per inflater call. Small enough that the first inflated
/// chunk of a crafted member is refused before much of it has been read.
const int _feedBytes = 16 * 1024;

class _ForwardingSink implements Sink<List<int>> {
  _ForwardingSink(this._output);
  final OutputStream _output;
  @override
  void add(List<int> data) => _output.writeBytes(data);
  @override
  void close() {}
}
