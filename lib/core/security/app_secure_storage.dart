import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One OS-keyring configuration for every secret owned by the app.
///
/// The Android and iOS options below each move a default towards "this device
/// only"; `docs/platform-setup.md` records the decisions and the upgrade path.
class AppSecureStorage {
  const AppSecureStorage._();

  /// Ad-hoc and local certificate builds have no Team ID, so they must use the
  /// classic macOS login keychain rather than the data-protection keychain.
  static const MacOsOptions macOsOptions = MacOsOptions(
    useDataProtectionKeyChain: false,
  );

  /// The plugin's Android default is its own cipher over plain
  /// `SharedPreferences`, a file that travels with any backup of the app's
  /// data. `EncryptedSharedPreferences` keeps the value under a Keystore key
  /// that cannot leave the device — which is the point of sealing the tokens
  /// at all: a master key that moves with the database it opens protects
  /// nothing (#300). The plugin migrates every existing entry on first open,
  /// so an upgrade keeps its key; below API 23 it falls back to the old store.
  static const AndroidOptions androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  /// The plugin's iOS default is `kSecAttrAccessibleWhenUnlocked`, which is
  /// eligible for migration to another device inside an encrypted backup.
  /// `…AfterFirstUnlockThisDeviceOnly` stays on this device, and is readable
  /// once the phone has been unlocked since boot — a capture that starts from
  /// the lock screen still needs its tokens. Reads do not filter on
  /// accessibility, so an item written under the old default is still found;
  /// the next write re-creates it under this one.
  static const IOSOptions iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  static const FlutterSecureStorage instance = FlutterSecureStorage(
    aOptions: androidOptions,
    iOptions: iosOptions,
    mOptions: macOsOptions,
  );
}
