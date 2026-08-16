import 'dart:io';

import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/local_transcription_service.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:augustyniak_capture/features/transcription/domain/local_transcription_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// Stands in for the native engine, the way `_FakeRegistrar` stands in for the
/// OS hotkey table: the suite stays pure Dart and never links anything.
class _FakeEngine implements LocalTranscriptionEngine {
  _FakeEngine({this.available = true});

  static const String text = 'transcribed here';
  final bool available;
  final List<String> modelPaths = <String>[];
  String? seenLanguage;

  @override
  bool get isAvailable => available;

  @override
  String? get unavailableReason => available ? null : 'no native engine here';

  @override
  Future<String> transcribe({
    required File audio,
    required String modelPath,
    String? language,
  }) async {
    modelPaths.add(modelPath);
    seenLanguage = language;
    return text;
  }
}

ProviderProfile _local({
  String model = 'base-q5',
  String? language,
  String endpoint = '',
}) => ProviderProfile(
  id: 'local-1',
  name: 'On-device base',
  endpoint: endpoint,
  kind: ProfileKind.localWhisper,
  model: model,
  language: language,
);

void main() {
  group('a local profile is not a remote one', () {
    test('toService refuses to invent a remote service for it', () {
      // The blank-endpoint guard is deliberate for a half-filled *remote*
      // profile. A local one has no endpoint by definition, so the kind is read
      // first — otherwise every on-device model would be silently disabled by
      // a rule written for a different mistake.
      expect(_local().toService(), isA<DisabledTranscriptionService>());
      // Even with an endpoint filled in by hand, the kind wins: a local profile
      // must never quietly start sending audio somewhere.
      expect(
        _local(endpoint: 'https://api.openai.com/v1/audio/transcriptions')
            .toService(),
        isA<DisabledTranscriptionService>(),
      );
    });

    test('a remote profile is unaffected', () {
      const ProviderProfile remote = ProviderProfile(
        id: 'p1',
        name: 'OpenAI',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
      );
      expect(remote.toService(), isA<HttpWhisperTranscriptionService>());
    });

    test('an older build reads the kind as transcription, and is inert', () {
      // `fromName` falls back rather than dropping, which is right for every
      // row written before kinds existed. Here it means an old build sees a
      // transcription profile with no endpoint — which its own guard degrades
      // to disabled. Inert, not destructive.
      expect(ProfileKind.fromName('localWhisper'), ProfileKind.localWhisper);
      expect(ProfileKind.fromName('somethingNewer'), ProfileKind.transcription);

      final ProviderProfile asOldBuildReadsIt = ProviderProfile.fromJson(
        <String, dynamic>{..._local().toJson(), 'kind': 'somethingNewer'},
      );
      expect(asOldBuildReadsIt.kind, ProfileKind.transcription);
      expect(
        asOldBuildReadsIt.toService(),
        isA<DisabledTranscriptionService>(),
      );
    });

    test('the kind round-trips', () {
      expect(
        ProviderProfile.fromJson(_local().toJson()).kind,
        ProfileKind.localWhisper,
      );
    });
  });

  group('the settings controller builds it', () {
    test('a local active profile yields the local service', () async {
      final SettingsController controller = buildSettingsController(
        stored: AppSettings(
          profiles: <ProviderProfile>[_local()],
          activeProfileId: 'local-1',
        ),
      );
      await controller.initialize();

      expect(controller.transcriptionService, isA<LocalTranscriptionService>());
    });

    test('switching a profile from remote to local swaps the service', () async {
      // The kind is in the cache signature because it decides *which* service
      // is built, not merely how one is configured — without it the cached
      // HTTP client would survive the switch.
      final SettingsController controller = buildSettingsController(
        stored: const AppSettings(
          profiles: <ProviderProfile>[
            ProviderProfile(
              id: 'p1',
              name: 'OpenAI',
              endpoint: 'https://api.openai.com/v1/audio/transcriptions',
            ),
          ],
          activeProfileId: 'p1',
        ),
      );
      await controller.initialize();
      expect(
        controller.transcriptionService,
        isA<HttpWhisperTranscriptionService>(),
      );

      await controller.updateProfile(
        controller.profiles.single.copyWith(kind: ProfileKind.localWhisper),
      );

      expect(controller.transcriptionService, isA<LocalTranscriptionService>());
    });

    test('an install with no engine says why, once', () async {
      final SettingsController controller = buildSettingsController();
      await controller.initialize();

      expect(controller.localEngineAvailable, isFalse);
      expect(controller.localEngineIssue, isNotNull);
    });
  });

  group('transcribing', () {
    late Directory dir;
    late File audio;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('augustyniak_local_asr_');
      audio = File('${dir.path}/capture.m4a')..writeAsStringSync('audio');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('hands the engine the resolved model path and the language', () async {
      final _FakeEngine engine = _FakeEngine();
      final LocalTranscriptionService service = LocalTranscriptionService(
        engine: engine,
        modelId: 'base-q5',
        modelPath: (String id) async => '/models/$id.bin',
        language: 'pl',
      );

      expect(await service.transcribe(audio), 'transcribed here');
      expect(engine.modelPaths, <String>['/models/base-q5.bin']);
      expect(engine.seenLanguage, 'pl');
    });

    test('the model path is resolved per call, not captured', () async {
      // A model can be deleted between two captures, and the second one has to
      // find that out rather than hand the engine a path to a file that is gone.
      final _FakeEngine engine = _FakeEngine();
      bool installed = true;
      final LocalTranscriptionService service = LocalTranscriptionService(
        engine: engine,
        modelId: 'base-q5',
        modelPath: (String id) async => installed ? '/models/$id.bin' : null,
      );

      await service.transcribe(audio);
      installed = false;
      await expectLater(
        service.transcribe(audio),
        throwsA(isA<LocalModelMissingException>()),
      );
    });

    test('an unavailable engine is a different failure from a missing model', () async {
      // The two call for opposite next actions: one is "this build cannot do it
      // at all", the other is "download the model you already chose".
      final LocalTranscriptionService service = LocalTranscriptionService(
        engine: _FakeEngine(available: false),
        modelId: 'base-q5',
        // Installed — and it still must not report the model as the problem.
        modelPath: (String id) async => '/models/$id.bin',
      );

      await expectLater(
        service.transcribe(audio),
        throwsA(isA<LocalTranscriptionUnavailableException>()),
      );
    });

    test('the default engine refuses rather than answering empty text', () async {
      // An empty transcript is a *result*. A capture that produced one silently
      // is indistinguishable from one this app could not read at all.
      await expectLater(
        const UnavailableLocalEngine().transcribe(
          audio: audio,
          modelPath: '/models/base.bin',
        ),
        throwsA(isA<LocalTranscriptionUnavailableException>()),
      );
    });

    test('a missing source file fails before the engine is asked', () async {
      final _FakeEngine engine = _FakeEngine();
      final LocalTranscriptionService service = LocalTranscriptionService(
        engine: engine,
        modelId: 'base-q5',
        modelPath: (String id) async => '/models/$id.bin',
      );

      await expectLater(
        service.transcribe(File('${dir.path}/gone.m4a')),
        throwsA(isA<FileSystemException>()),
      );
      expect(engine.modelPaths, isEmpty);
    });
  });

  group('the capture survives a local failure', () {
    test('the item lands failed, retryable, with its source intact', () async {
      final Directory appDir = Directory.systemTemp.createTempSync(
        'augustyniak_local_capture_',
      );
      addTearDown(() => appDir.deleteSync(recursive: true));

      // Seeded and retried rather than recorded: the fake recorder answers no
      // permission, and what this asserts is the *processing* half anyway.
      final File source = File('${appDir.path}/r1.m4a')
        ..writeAsStringSync('audio');
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(
            id: 'r1',
            status: RecordingStatus.saved,
            filePath: source.path,
          ),
        ],
        service: LocalTranscriptionService(
          engine: _FakeEngine(available: false),
          modelId: 'base-q5',
          modelPath: (String id) async => '/models/$id.bin',
        ),
      );

      await controller.retryTranscription('r1');
      await controller.waitForProcessing();

      final Recording item = controller.recordings.single;
      expect(item.status, RecordingStatus.failed);
      expect(item.error, contains('no native engine here'));
      // The rule the whole app rests on: a transcription failure never costs
      // the recording.
      expect(File(item.filePath).existsSync(), isTrue);
    });
  });
}
