import 'dart:io';
import 'dart:typed_data';

import 'package:augustyniak_capture/features/recordings/data/wav_stream_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('wav_writer_test');
    file = File('${dir.path}/take.wav');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Uint8List pcm(int bytes, int fill) =>
      Uint8List.fromList(List<int>.filled(bytes, fill));

  ByteData header(File f) =>
      ByteData.sublistView(Uint8List.fromList(f.readAsBytesSync()));

  String tag(ByteData d, int offset) => String.fromCharCodes(
    Iterable<int>.generate(4, (int i) => d.getUint8(offset + i)),
  );

  test(
    'an unclosed file is readable: header with open-ended sizes, then PCM',
    () async {
      final WavStreamWriter writer = await WavStreamWriter.open(
        file,
        sampleRate: 16000,
      );
      await writer.write(pcm(100, 5));

      // No close(): this is what a crash leaves behind. Every chunk was flushed,
      // so the bytes are on disk, and the sizes say "unknown length".
      final Uint8List bytes = file.readAsBytesSync();
      expect(bytes.length, 144);
      final ByteData d = ByteData.sublistView(bytes);
      expect(tag(d, 0), 'RIFF');
      expect(d.getUint32(4, Endian.little), 0xFFFFFFFF);
      expect(tag(d, 8), 'WAVE');
      expect(tag(d, 12), 'fmt ');
      expect(d.getUint32(16, Endian.little), 16);
      expect(d.getUint16(20, Endian.little), 1);
      expect(d.getUint16(22, Endian.little), 1);
      expect(d.getUint32(24, Endian.little), 16000);
      expect(d.getUint32(28, Endian.little), 32000);
      expect(d.getUint16(32, Endian.little), 2);
      expect(d.getUint16(34, Endian.little), 16);
      expect(tag(d, 36), 'data');
      expect(d.getUint32(40, Endian.little), 0xFFFFFFFF);
      expect(bytes.sublist(44), pcm(100, 5));

      await writer.close();
    },
  );

  test('close patches the RIFF and data sizes', () async {
    final WavStreamWriter writer = await WavStreamWriter.open(
      file,
      sampleRate: 24000,
    );
    await writer.write(pcm(300, 1));
    await writer.write(pcm(200, 2));
    await writer.close();

    final ByteData d = header(file);
    expect(file.lengthSync(), 544);
    expect(d.getUint32(4, Endian.little), 544 - 8);
    expect(d.getUint32(40, Endian.little), 500);
    expect(d.getUint32(24, Endian.little), 24000);
    expect(d.getUint32(28, Endian.little), 48000);
    expect(writer.bytesWritten, 500);
  });

  test('a take with no audio closes to a header-only file', () async {
    final WavStreamWriter writer = await WavStreamWriter.open(
      file,
      sampleRate: 16000,
    );
    await writer.close();
    expect(file.lengthSync(), 44);
    expect(header(file).getUint32(40, Endian.little), 0);
    expect(writer.bytesWritten, 0);
  });

  test('unawaited writes keep their order', () async {
    final WavStreamWriter writer = await WavStreamWriter.open(
      file,
      sampleRate: 16000,
    );
    writer.write(pcm(4, 1));
    writer.write(pcm(4, 2));
    writer.write(pcm(4, 3));
    await writer.close();
    expect(file.readAsBytesSync().sublist(44), <int>[
      ...pcm(4, 1),
      ...pcm(4, 2),
      ...pcm(4, 3),
    ]);
  });

  test('close is idempotent and a write after close is dropped', () async {
    final WavStreamWriter writer = await WavStreamWriter.open(
      file,
      sampleRate: 16000,
    );
    await writer.write(pcm(10, 1));
    await writer.close();
    await writer.close();
    await writer.write(pcm(10, 2));
    expect(file.lengthSync(), 54);
    expect(header(file).getUint32(40, Endian.little), 10);
  });
}
