import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
        _live(endpoint: 'https://api.openai.com/v1/audio/transcriptions')
            .toService(),
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
}
