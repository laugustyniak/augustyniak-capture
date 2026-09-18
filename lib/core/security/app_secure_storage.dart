import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One OS-keyring configuration for every secret owned by the app.
class AppSecureStorage {
  const AppSecureStorage._();

  /// Ad-hoc and local certificate builds have no Team ID, so they must use the
  /// classic macOS login keychain rather than the data-protection keychain.
  static const MacOsOptions macOsOptions = MacOsOptions(
    useDataProtectionKeyChain: false,
  );

  static const FlutterSecureStorage instance = FlutterSecureStorage(
    mOptions: macOsOptions,
  );
}
