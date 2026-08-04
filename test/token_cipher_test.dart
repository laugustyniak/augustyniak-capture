import 'package:flutter_test/flutter_test.dart';
import 'package:audivoa_core/features/settings/domain/token_cipher.dart';

void main() {
  group('TokenCipher.isSealed', () {
    test('detects the enc:v1: prefix', () {
      expect(TokenCipher.isSealed('enc:v1:abc'), isTrue);
      expect(TokenCipher.isSealed('sk-secret'), isFalse);
      expect(TokenCipher.isSealed(''), isFalse);
    });
  });

  group('PlaintextTokenCipher', () {
    const PlaintextTokenCipher cipher = PlaintextTokenCipher();

    test('does not encrypt', () {
      expect(cipher.encrypts, isFalse);
    });

    test('seal and unseal are identity transforms', () async {
      await cipher.ensureReady();
      expect(await cipher.seal('sk-secret'), 'sk-secret');
      expect(await cipher.unseal('sk-secret'), 'sk-secret');
      // A sealed blob passes through untouched — preservation, not decryption.
      expect(await cipher.unseal('enc:v1:blob'), 'enc:v1:blob');
    });
  });
}
