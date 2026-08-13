import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:flutter_test/flutter_test.dart';

/// A provider profile decides where the bearer token, the audio and the
/// transcript go — and over what. The endpoint is free text with a
/// `Uri.hasScheme` guard behind it, which accepts `http://` exactly as readily
/// as `https://`, so a typo or a copied example can put an API key and a
/// dictated note on the wire in the clear with nothing on screen saying so.
///
/// It cannot simply be refused: this app documents `http://localhost:11434`
/// (Ollama) and `http://localhost:8080` (llama.cpp) as first-class setups, and
/// a model server on the user's own LAN is the same decision. Plain HTTP to a
/// machine the user controls is a choice; plain HTTP to a host on the internet
/// is almost always an accident.
void main() {
  ProviderProfile profileAt(String endpoint) => ProviderProfile(
    id: 'p1',
    name: 'Test',
    endpoint: endpoint,
    bearerToken: 'token',
  );

  group('ProviderProfile.usesInsecureTransport', () {
    test('https is never flagged', () {
      expect(
        profileAt('https://api.openai.com/v1/chat/completions')
            .usesInsecureTransport,
        isFalse,
      );
    });

    test('plain http to a public host is flagged', () {
      expect(
        profileAt('http://api.example.com/v1/chat/completions')
            .usesInsecureTransport,
        isTrue,
      );
    });

    test('a local model server is not flagged — it is a documented setup', () {
      // The two endpoints ProviderPreset.all ships for local inference.
      expect(
        profileAt('http://localhost:11434/v1/chat/completions')
            .usesInsecureTransport,
        isFalse,
      );
      expect(
        profileAt('http://localhost:8080/inference').usesInsecureTransport,
        isFalse,
      );
      expect(
        profileAt('http://127.0.0.1:8080/inference').usesInsecureTransport,
        isFalse,
      );
      expect(
        profileAt('http://[::1]:8080/inference').usesInsecureTransport,
        isFalse,
      );
    });

    test('a server on the user\'s own network is not flagged either', () {
      // A box under the desk running a model is the same decision as localhost,
      // and flagging it would train the warning away.
      for (final String host in <String>[
        '192.168.1.5',
        '10.0.0.5',
        '172.16.0.1',
        '172.31.255.255',
      ]) {
        expect(
          profileAt('http://$host:8080/inference').usesInsecureTransport,
          isFalse,
          reason: host,
        );
      }
    });

    test('an address just outside the private range is flagged', () {
      // 172.32.x is public. Getting the 172.16/12 boundary wrong in the
      // permissive direction is what makes a warning like this useless.
      expect(
        profileAt('http://172.32.0.1:8080/inference').usesInsecureTransport,
        isTrue,
      );
      expect(
        profileAt('http://172.15.0.1:8080/inference').usesInsecureTransport,
        isTrue,
      );
    });

    test('an unusable endpoint is not flagged — it reaches nothing', () {
      // A blank or schemeless profile already degrades to the disabled
      // service, and a second complaint about it would be noise.
      expect(profileAt('').usesInsecureTransport, isFalse);
      expect(profileAt('api.example.com').usesInsecureTransport, isFalse);
    });

    test('the scheme is read case-insensitively', () {
      expect(
        profileAt('HTTP://api.example.com/v1').usesInsecureTransport,
        isTrue,
      );
    });
  });
}
