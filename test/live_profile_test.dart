import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/live/deepgram_live_service.dart';
import 'package:augustyniak_capture/features/transcription/data/live/openai_live_service.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:augustyniak_capture/features/transcription/domain/live_transcription.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

ProviderProfile _live({
  String endpoint = 'wss://api.deepgram.com/v1/listen',
  String id = 'live-1',
}) => ProviderProfile(
  id: id,
  name: 'Deepgram',
  endpoint: endpoint,
  kind: ProfileKind.liveTranscription,
  model: 'nova-3',
  language: 'pl',
  bearerToken: 'k',
);

void main() {
  group('ProfileKind.liveTranscription', () {
    test('round-trips and is remote', () {
      expect(
        ProfileKind.fromName('liveTranscription'),
        ProfileKind.liveTranscription,
      );
      expect(
        ProviderProfile.fromJson(_live().toJson()).kind,
        ProfileKind.liveTranscription,
      );
      expect(ProfileKind.liveTranscription.isRemote, isTrue);
      expect(ProfileKind.liveTranscription.label, 'LIVE DICTATION PROFILES');
    });

    test('is last in the enum so stored names never shift', () {
      expect(ProfileKind.values.last, ProfileKind.liveTranscription);
    });

    test('toService never builds an HTTP whisper client for it', () {
      expect(_live().toService(), isA<DisabledTranscriptionService>());
      expect(
        _live(
          endpoint: 'https://api.openai.com/v1/audio/transcriptions',
        ).toService(),
        isA<DisabledTranscriptionService>(),
      );
    });

    test('wss is not flagged insecure, public ws is', () {
      expect(_live().usesInsecureTransport, isFalse);
      expect(
        _live(endpoint: 'ws://203.0.113.10/listen').usesInsecureTransport,
        isTrue,
      );
      expect(
        _live(endpoint: 'ws://127.0.0.1:9/listen').usesInsecureTransport,
        isFalse,
      );
    });

    test('an older build reads it as transcription and stays inert', () {
      final ProviderProfile old = ProviderProfile.fromJson(<String, dynamic>{
        ..._live().toJson(),
        'kind': 'somethingNewer',
      });
      expect(old.kind, ProfileKind.transcription);
      expect(old.toService(), isA<DisabledTranscriptionService>());
    });
  });

  group('AppSettings.activeLiveProfileId', () {
    test('round-trips and resolves the profile', () {
      final AppSettings s = AppSettings.empty.copyWith(
        profiles: <ProviderProfile>[_live()],
        activeLiveProfileId: 'live-1',
      );
      final AppSettings back = AppSettings.fromJson(s.toJson());
      expect(back.activeLiveProfileId, 'live-1');
      expect(back.activeLiveProfile?.id, 'live-1');
    });

    test('legacy JSON without the key reads as null', () {
      final Map<String, dynamic> json = AppSettings.empty.toJson()
        ..remove('activeLiveProfileId');
      final AppSettings back = AppSettings.fromJson(json);
      expect(back.activeLiveProfileId, isNull);
      expect(back.activeLiveProfile, isNull);
    });

    test('a dangling id resolves to null and clear drops it', () {
      final AppSettings s = AppSettings.empty.copyWith(
        activeLiveProfileId: 'ghost',
      );
      expect(s.activeLiveProfile, isNull);
      expect(
        s.copyWith(clearActiveLiveProfileId: true).activeLiveProfileId,
        isNull,
      );
    });
  });

  group('SettingsController live wiring', () {
    Future<SettingsController> build([AppSettings? stored]) async {
      final SettingsController c = buildSettingsController(stored: stored);
      await c.initialize();
      return c;
    }

    test('nothing configured means a disabled live service', () async {
      final SettingsController c = await build();
      expect(
        c.liveTranscriptionService,
        isA<DisabledLiveTranscriptionService>(),
      );
      expect(c.liveTranscriptionService.isAvailable, isFalse);
    });

    test('adding a live profile activates it, and only it', () async {
      final SettingsController c = await build();
      final ProviderProfile first = await c.addProfile(
        name: 'HTTP',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
      );
      final ProviderProfile live = await c.addProfile(
        name: 'Deepgram',
        endpoint: 'wss://api.deepgram.com/v1/listen',
        kind: ProfileKind.liveTranscription,
        model: 'nova-3',
        language: 'pl',
        bearerToken: 'k',
      );
      expect(c.settings.activeProfileId, first.id);
      expect(c.settings.activeLiveProfileId, live.id);
      expect(c.liveTranscriptionService, isA<DeepgramLiveService>());
      expect(c.liveTranscriptionService.sampleRate, 16000);
    });

    test('the OpenAI host builds the 24 kHz adapter', () async {
      final SettingsController c = await build();
      await c.addProfile(
        name: 'OpenAI live',
        endpoint: 'wss://api.openai.com/v1/realtime?intent=transcription',
        kind: ProfileKind.liveTranscription,
      );
      expect(c.liveTranscriptionService, isA<OpenAiLiveService>());
      expect(c.liveTranscriptionService.sampleRate, 24000);
    });

    test(
      'an https, public ws or unknown-host endpoint stays disabled',
      () async {
        for (final String endpoint in <String>[
          'https://api.deepgram.com/v1/listen',
          'ws://api.deepgram.com/v1/listen',
          'wss://stt.example.org/listen',
          '',
        ]) {
          final SettingsController c = await build();
          await c.addProfile(
            name: 'x',
            endpoint: endpoint,
            kind: ProfileKind.liveTranscription,
          );
          expect(
            c.liveTranscriptionService,
            isA<DisabledLiveTranscriptionService>(),
            reason: endpoint,
          );
        }
      },
    );

    test('the service is cached until the connection details change', () async {
      final SettingsController c = await build();
      final ProviderProfile live = await c.addProfile(
        name: 'Deepgram',
        endpoint: 'wss://api.deepgram.com/v1/listen',
        kind: ProfileKind.liveTranscription,
      );
      final LiveTranscriptionService a = c.liveTranscriptionService;
      expect(identical(a, c.liveTranscriptionService), isTrue);
      await c.updateProfile(live.copyWith(language: 'en'));
      expect(identical(a, c.liveTranscriptionService), isFalse);
    });

    test(
      'deleting the active live profile falls back within its kind',
      () async {
        final SettingsController c = await build();
        final ProviderProfile one = await c.addProfile(
          name: 'one',
          endpoint: 'wss://api.deepgram.com/v1/listen',
          kind: ProfileKind.liveTranscription,
        );
        final ProviderProfile two = await c.addProfile(
          name: 'two',
          endpoint: 'wss://api.openai.com/v1/realtime',
          kind: ProfileKind.liveTranscription,
        );
        final ProviderProfile http = await c.addProfile(
          name: 'http',
          endpoint: 'https://api.openai.com/v1/audio/transcriptions',
        );
        expect(c.settings.activeLiveProfileId, two.id);
        await c.deleteProfile(two.id);
        expect(c.settings.activeLiveProfileId, one.id);
        await c.deleteProfile(one.id);
        expect(c.settings.activeLiveProfileId, isNull);
        expect(c.settings.activeProfileId, http.id);
      },
    );

    test('setActiveLiveProfile selects and clears', () async {
      final SettingsController c = await build();
      final ProviderProfile one = await c.addProfile(
        name: 'one',
        endpoint: 'wss://api.deepgram.com/v1/listen',
        kind: ProfileKind.liveTranscription,
      );
      await c.addProfile(
        name: 'two',
        endpoint: 'wss://api.openai.com/v1/realtime',
        kind: ProfileKind.liveTranscription,
      );
      await c.setActiveLiveProfile(one.id);
      expect(c.activeLiveProfile?.id, one.id);
      await c.setActiveLiveProfile(null);
      expect(c.activeLiveProfile, isNull);
    });
  });
}
