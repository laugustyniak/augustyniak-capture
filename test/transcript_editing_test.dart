import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audivoa_core/features/recordings/data/recordings_repository.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

class _FakeRepo extends RecordingsRepository {
  _FakeRepo(this._items);
  List<Recording> _items;
  int saveCount = 0;
  @override
  Future<List<Recording>> loadAll() async => _items;
  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saveCount++;
    _items = List<Recording>.of(recordings);
  }
}

Recording _seed() => Recording(
  id: 'r1',
  filePath: '/tmp/r1.m4a',
  createdAt: DateTime.utc(2026, 7, 25),
  durationMs: 1000,
  status: RecordingStatus.completed,
  transcript: 'oryginalny tekst',
);

RecordingsController _controller(_FakeRepo repo) => RecordingsController(
  repository: repo,
  transcriptionService: const DisabledTranscriptionService(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final String name in <String>[
    'com.llfbandit.record/messages',
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    messenger.setMockMethodCallHandler(
      MethodChannel(name),
      (MethodCall call) async => null,
    );
  }

  group('editTranscript', () {
    test('overwrites the text (trimmed) and persists', () async {
      final _FakeRepo repo = _FakeRepo(<Recording>[_seed()]);
      final RecordingsController c = _controller(repo);
      addTearDown(c.dispose);
      await c.initialize();

      await c.editTranscript('r1', '  poprawiony tekst  ');

      expect(c.recordings.single.transcript, 'poprawiony tekst');
      expect(repo.saveCount, greaterThan(0));
    });

    test('a blank edit is ignored', () async {
      final _FakeRepo repo = _FakeRepo(<Recording>[_seed()]);
      final RecordingsController c = _controller(repo);
      addTearDown(c.dispose);
      await c.initialize();

      await c.editTranscript('r1', '   ');

      expect(c.recordings.single.transcript, 'oryginalny tekst');
    });
  });

  group('setTitle', () {
    test('sets a trimmed title', () async {
      final _FakeRepo repo = _FakeRepo(<Recording>[_seed()]);
      final RecordingsController c = _controller(repo);
      addTearDown(c.dispose);
      await c.initialize();

      await c.setTitle('r1', '  Spotkanie  ');
      expect(c.recordings.single.title, 'Spotkanie');
    });

    test('an empty title clears it back to null', () async {
      final _FakeRepo repo = _FakeRepo(<Recording>[_seed()]);
      final RecordingsController c = _controller(repo);
      addTearDown(c.dispose);
      await c.initialize();

      await c.setTitle('r1', 'Tytuł');
      expect(c.recordings.single.title, 'Tytuł');

      await c.setTitle('r1', '   ');
      expect(c.recordings.single.title, isNull);
    });
  });
}
