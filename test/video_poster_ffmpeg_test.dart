import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:audivoa_core/features/processing/data/video_poster_extractor.dart';

/// The one suite in the repo that drives a **real** system binary.
///
/// Everything else about posters is asserted against a fake extractor, which
/// proves the controller's contract and nothing at all about the ffmpeg
/// invocation itself — a wrong flag, a codec ffmpeg refuses to write, or a seek
/// past the end of a short clip would all sail through those tests and fail on
/// a user's first video. So this file generates a genuine clip with `lavfi`,
/// runs `FfmpegVideoPosterExtractor` over it, and checks the two things only a
/// real run can show: that a decodable JPEG comes out, and that the source is
/// byte-for-byte what it was ("a processor only ever reads the source").
///
/// There is no CI here and another machine may not have ffmpeg, so the whole
/// group **skips** rather than fails when the binary is absent.
String? ffmpegSkipReason() {
  try {
    final ProcessResult probe = Process.runSync('ffmpeg', <String>['-version']);
    if (probe.exitCode != 0) {
      return 'ffmpeg exited ${probe.exitCode} for `-version` — '
          'the real-binary poster test needs a working ffmpeg.';
    }
    return null;
  } on ProcessException {
    return 'ffmpeg is not on PATH — skipping the real-binary poster test. '
        'Install it (`sudo apt-get install ffmpeg`) to run this suite.';
  }
}

/// `testsrc` is ffmpeg's own synthetic pattern generator, so the fixture needs
/// no checked-in binary asset. `yuv420p` keeps the clip readable by anything.
Future<File> generateClip(Directory dir, String name, String seconds) async {
  final File file = File(p.join(dir.path, name));
  final ProcessResult result = await Process.run('ffmpeg', <String>[
    '-y',
    '-loglevel',
    'error',
    '-f',
    'lavfi',
    '-i',
    'testsrc=duration=$seconds:size=160x120:rate=5',
    '-pix_fmt',
    'yuv420p',
    file.path,
  ], stderrEncoding: SystemEncoding());
  if (result.exitCode != 0 || !await file.exists()) {
    throw StateError('Could not build the fixture clip: ${result.stderr}');
  }
  return file;
}

void main() {
  final String? skip = ffmpegSkipReason();

  group('FfmpegVideoPosterExtractor against the real binary', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('ffreal'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('extracts a decodable JPEG and leaves the video untouched', () async {
      final File video = await generateClip(tmp, 'clip.mp4', '2');
      final Uint8List before = await video.readAsBytes();
      final DateTime modifiedBefore = await video.lastModified();
      final File destination = File(p.join(tmp.path, 'clip.thumb.jpg'));

      final File poster = await const FfmpegVideoPosterExtractor()
          .extractPoster(video, destination);

      expect(poster.path, destination.path);
      final Uint8List bytes = await poster.readAsBytes();
      expect(bytes, isNotEmpty);
      // SOI … EOI: a truncated write (a killed ffmpeg) would satisfy "non-empty"
      // but not this, and it is what the queue would render as a broken tile.
      expect(bytes.sublist(0, 2), <int>[0xFF, 0xD8], reason: 'JPEG SOI marker');
      expect(bytes.sublist(bytes.length - 2), <int>[
        0xFF,
        0xD9,
      ], reason: 'JPEG EOI marker');

      // The rule this suite exists to prove with a real binary: a processor only
      // ever *reads* its source.
      expect(await video.readAsBytes(), orderedEquals(before));
      expect(await video.lastModified(), modifiedBefore);

      // And it writes exactly one thing: the poster the caller named. A stray
      // `clip.thumb.jpg.tmp` or a numbered image-sequence file would mean the
      // recordings directory silently accumulating junk beside the sources.
      final List<String> left =
          tmp
              .listSync()
              .map((FileSystemEntity entity) => p.basename(entity.path))
              .toList()
            ..sort();
      expect(left, <String>['clip.mp4', 'clip.thumb.jpg']);
    }, skip: skip);

    test('a clip shorter than the seek point still yields a poster', () async {
      // The `-ss 1` first attempt is what makes a phone clip's black opening
      // frame not become the poster; the cost is that a 0.4 s clip has nothing
      // at that timestamp, so the retry from 0 is the only thing standing
      // between a short capture and a permanently posterless card.
      final File video = await generateClip(tmp, 'short.mp4', '0.4');

      // Control run: prove the seek really does come back empty here, so the
      // assertion below is about the retry rather than about ffmpeg being
      // lenient.
      final File control = File(p.join(tmp.path, 'control.jpg'));
      await Process.run('ffmpeg', <String>[
        '-y',
        '-loglevel',
        'error',
        '-ss',
        '1',
        '-i',
        video.path,
        '-frames:v',
        '1',
        '-f',
        'image2',
        control.path,
      ], stderrEncoding: SystemEncoding());
      expect(
        control.existsSync() && control.lengthSync() > 0,
        isFalse,
        reason: 'seeking past the end of the clip should encode nothing',
      );

      final File poster = await const FfmpegVideoPosterExtractor()
          .extractPoster(video, File(p.join(tmp.path, 'short.thumb.jpg')));

      final Uint8List bytes = await poster.readAsBytes();
      expect(bytes, isNotEmpty);
      expect(bytes.sublist(0, 2), <int>[0xFF, 0xD8]);
      expect(bytes.sublist(bytes.length - 2), <int>[0xFF, 0xD9]);
    }, skip: skip);
  });
}
