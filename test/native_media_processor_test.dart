import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/processing/data/native_media_processor.dart';
import 'package:augustyniak_capture/features/transcription/data/audio_splitter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(
    'ai.augustyniak.capture/media_processing',
  );
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('native_media_test');
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('extractAudio returns the validated native output', () async {
    final File source = File(p.join(temp.path, 'clip.mp4'))
      ..writeAsBytesSync(<int>[1]);
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'extractVideoAudio');
      final Map<Object?, Object?> arguments =
          call.arguments as Map<Object?, Object?>;
      File(arguments['outputPath']! as String).writeAsBytesSync(<int>[2, 3]);
      return null;
    });

    final File output = await const NativeMobileMediaProcessor().extractAudio(
      source,
    );

    expect(await output.readAsBytes(), <int>[2, 3]);
    addTearDown(() async {
      final Directory parent = output.parent;
      if (await parent.exists()) await parent.delete(recursive: true);
    });
  });

  test(
    'extractPoster removes a partial destination after native failure',
    () async {
      final File source = File(p.join(temp.path, 'clip.mp4'))
        ..writeAsBytesSync(<int>[1]);
      final File destination = File(p.join(temp.path, 'poster.jpg'));
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        destination.writeAsBytesSync(<int>[9]);
        throw PlatformException(code: 'native_media_error');
      });

      await expectLater(
        const NativeMobileMediaProcessor().extractPoster(source, destination),
        throwsA(isA<PlatformException>()),
      );
      expect(await destination.exists(), isFalse);
    },
  );

  test('split returns owned segments and dispose removes them', () async {
    final File source = File(p.join(temp.path, 'audio.m4a'))
      ..writeAsBytesSync(<int>[1]);
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'splitAudio');
      final Map<Object?, Object?> arguments =
          call.arguments as Map<Object?, Object?>;
      final Directory output = Directory(
        arguments['outputDirectory']! as String,
      );
      final File first = File(p.join(output.path, 'part_00000.m4a'))
        ..writeAsBytesSync(<int>[1]);
      final File second = File(p.join(output.path, 'part_00001.m4a'))
        ..writeAsBytesSync(<int>[2]);
      return <String>[first.path, second.path];
    });

    final AudioSegments segments = await const NativeMobileMediaProcessor()
        .split(source, const Duration(minutes: 5));
    final Directory outputDirectory = segments.files.first.parent;

    expect(segments.isSplit, isTrue);
    expect(segments.files, hasLength(2));
    await segments.dispose();
    expect(await outputDirectory.exists(), isFalse);
  });
}
