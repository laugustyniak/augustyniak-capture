import 'package:flutter_test/flutter_test.dart';
import 'package:audivoa_core/features/settings/domain/provider_profile.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

void main() {
  group('ProviderProfile.usableBearerToken', () {
    test('passes a plaintext token through', () {
      const ProviderProfile profile = ProviderProfile(
        id: 'p',
        name: 'OpenAI',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
        bearerToken: 'sk-secret',
      );
      expect(profile.usableBearerToken, 'sk-secret');
    });

    test('is null for null and blank tokens', () {
      const ProviderProfile none = ProviderProfile(
        id: 'p',
        name: 'X',
        endpoint: 'https://example.com',
      );
      const ProviderProfile blank = ProviderProfile(
        id: 'p',
        name: 'X',
        endpoint: 'https://example.com',
        bearerToken: '   ',
      );
      expect(none.usableBearerToken, isNull);
      expect(blank.usableBearerToken, isNull);
    });

    test('is null for a still-sealed blob, and the service omits it', () {
      const ProviderProfile profile = ProviderProfile(
        id: 'p',
        name: 'OpenAI',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
        bearerToken: 'enc:v1:unreadable-blob',
      );

      expect(profile.usableBearerToken, isNull);

      // The sealed blob must never reach an Authorization header.
      final HttpWhisperTranscriptionService service =
          profile.toService() as HttpWhisperTranscriptionService;
      expect(service.bearerToken, isNull);
    });
  });
}
