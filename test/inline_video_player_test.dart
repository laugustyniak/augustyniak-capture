import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:augustyniak_capture/features/recordings/presentation/inline_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAudioPlayer implements AudioPlayer {
  final StreamController<Duration> positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> durationController =
      StreamController<Duration>.broadcast();
  final StreamController<PlayerState> stateController =
      StreamController<PlayerState>.broadcast();
  final StreamController<void> completeController =
      StreamController<void>.broadcast();

  Source? lastSource;
  Duration? lastSeekPosition;
  double lastVolume = 1.0;
  bool isPlaying = false;
  bool isPaused = false;
  bool isStopped = false;

  @override
  Stream<Duration> get onPositionChanged => positionController.stream;

  @override
  Stream<Duration> get onDurationChanged => durationController.stream;

  @override
  Stream<PlayerState> get onPlayerStateChanged => stateController.stream;

  @override
  Stream<void> get onPlayerComplete => completeController.stream;

  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    lastSource = source;
    isPlaying = true;
    isPaused = false;
    isStopped = false;
    stateController.add(PlayerState.playing);
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
    isPaused = true;
    stateController.add(PlayerState.paused);
  }

  @override
  Future<void> stop() async {
    isPlaying = false;
    isStopped = true;
    stateController.add(PlayerState.stopped);
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeekPosition = position;
    positionController.add(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    lastVolume = volume;
  }

  void emitPosition(Duration position) => positionController.add(position);
  void emitDuration(Duration duration) => durationController.add(duration);
  void emitComplete() => completeController.add(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late Directory tempDir;
  late File videoFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('video_player_test_');
    videoFile = File('${tempDir.path}/test_clip.mp4');
    await videoFile.writeAsBytes(<int>[0, 0, 0, 20, 1, 2, 3]);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('VideoPlaybackController', () {
    test('initializes cleanly when video file exists', () async {
      final VideoPlaybackController controller = VideoPlaybackController(
        videoFile: videoFile,
        duration: const Duration(seconds: 30),
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.hasError, isFalse);
      expect(controller.error, isNull);
      expect(controller.duration, const Duration(seconds: 30));
      expect(controller.position, Duration.zero);
      expect(controller.isPlaying, isFalse);
    });

    test('sets error state when video file is missing', () async {
      final File missingFile = File('${tempDir.path}/missing.mp4');
      final VideoPlaybackController controller = VideoPlaybackController(
        videoFile: missingFile,
        duration: const Duration(seconds: 30),
        autoInitialize: false,
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.hasError, isTrue);
      expect(controller.error, contains('Video file is missing'));
      expect(controller.isPlaying, isFalse);
    });

    test('play, pause, and togglePlay update playback state', () async {
      final _FakeAudioPlayer fakePlayer = _FakeAudioPlayer();
      final VideoPlaybackController controller = VideoPlaybackController(
        videoFile: videoFile,
        duration: const Duration(seconds: 15),
        player: fakePlayer,
        autoInitialize: false,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.play();
      expect(controller.isPlaying, isTrue);
      expect(fakePlayer.isPlaying, isTrue);

      await controller.pause();
      expect(controller.isPlaying, isFalse);
      expect(fakePlayer.isPaused, isTrue);

      await controller.togglePlay();
      expect(controller.isPlaying, isTrue);

      await controller.togglePlay();
      expect(controller.isPlaying, isFalse);
    });

    test('seek clamps within [0, duration]', () async {
      final _FakeAudioPlayer fakePlayer = _FakeAudioPlayer();
      final VideoPlaybackController controller = VideoPlaybackController(
        videoFile: videoFile,
        duration: const Duration(seconds: 20),
        player: fakePlayer,
        autoInitialize: false,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.seek(const Duration(seconds: 10));
      expect(controller.position, const Duration(seconds: 10));
      expect(fakePlayer.lastSeekPosition, const Duration(seconds: 10));

      // Over duration limit clamps to duration
      await controller.seek(const Duration(seconds: 50));
      expect(controller.position, const Duration(seconds: 20));

      // Negative clamps to 0
      await controller.seek(const Duration(seconds: -5));
      expect(controller.position, Duration.zero);
    });

    test('volume and mute controls work properly', () async {
      final _FakeAudioPlayer fakePlayer = _FakeAudioPlayer();
      final VideoPlaybackController controller = VideoPlaybackController(
        videoFile: videoFile,
        duration: const Duration(seconds: 20),
        player: fakePlayer,
        autoInitialize: false,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.setVolume(0.5);
      expect(controller.volume, 0.5);
      expect(controller.isMuted, isFalse);
      expect(fakePlayer.lastVolume, 0.5);

      await controller.toggleMute();
      expect(controller.isMuted, isTrue);

      await controller.toggleMute();
      expect(controller.isMuted, isFalse);
    });

    test('reaches completion on player complete and resets appropriately', () async {
      final _FakeAudioPlayer fakePlayer = _FakeAudioPlayer();
      final VideoPlaybackController controller = VideoPlaybackController(
        videoFile: videoFile,
        duration: const Duration(seconds: 10),
        player: fakePlayer,
        autoInitialize: false,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.play();
      expect(controller.isPlaying, isTrue);

      fakePlayer.emitComplete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.isPlaying, isFalse);
      expect(controller.position, const Duration(seconds: 10));

      // Playing after completion seeks back to 0
      await controller.play();
      expect(controller.position, Duration.zero);
      expect(controller.isPlaying, isTrue);
    });

    test('retry clears previous error and reinitializes', () async {
      final File missingFile = File('${tempDir.path}/retry_test.mp4');
      final VideoPlaybackController controller = VideoPlaybackController(
        videoFile: missingFile,
        duration: const Duration(seconds: 10),
        autoInitialize: false,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.hasError, isTrue);

      // Create file now
      await missingFile.writeAsBytes(<int>[1, 2, 3]);
      await controller.retry();

      expect(controller.hasError, isFalse);
      expect(controller.error, isNull);
    });

    test('disposing cleans up without throwing', () async {
      final VideoPlaybackController controller = VideoPlaybackController(
        videoFile: videoFile,
        duration: const Duration(seconds: 10),
      );
      await controller.initialize();
      expect(controller.isDisposed, isFalse);

      controller.dispose();
      expect(controller.isDisposed, isTrue);

      // Subsequent actions should be safe no-ops
      await controller.play();
      await controller.seek(const Duration(seconds: 5));
    });
  });
}
