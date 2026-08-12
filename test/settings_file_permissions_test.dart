import 'dart:io';

import 'package:augustyniak_capture/features/settings/data/settings_repository.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Same seam as `settings_encryption_test.dart`: the repository's own file
/// override, so the test writes to a temp path instead of the app's documents
/// directory.
class _TempFileSettingsRepository extends SettingsRepository {
  _TempFileSettingsRepository(this.file);

  final File file;

  @override
  Future<File?> settingsFile() async => file;
}

/// A settings file holds provider bearer tokens, and holds them **in the clear**
/// whenever the key store is unavailable — a headless Linux box with no Secret
/// Service, or a macOS build whose keychain access was refused. That is the
/// documented fallback rather than a bug, which is exactly why the file it
/// falls back to must not be readable by every account on the machine.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('settings-perms-');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a saved settings file is readable by its owner only', () async {
    final File file = File(p.join(dir.path, 'settings.json'));
    final _TempFileSettingsRepository repository =
        _TempFileSettingsRepository(file);

    await repository.save(
      const AppSettings(
        profiles: <ProviderProfile>[
          ProviderProfile(
            id: 'p1',
            name: 'OpenAI',
            endpoint: 'https://api.openai.com/v1/audio/transcriptions',
            bearerToken: 'plaintext',
          ),
        ],
      ),
    );

    expect(file.existsSync(), isTrue);
    expect(file.statSync().mode & 0x1FF, 0x180); // 0600
  }, skip: Platform.isWindows);

  test('the temp file is restricted before it takes the final name', () async {
    // `save` writes `.tmp` and renames. Tightening after the rename would leave
    // the tokens world-readable at their real path for the width of a syscall,
    // which is the same ordering `FileMasterKeyStore.write` already gets right.
    final File file = File(p.join(dir.path, 'settings.json'));
    await _TempFileSettingsRepository(file).save(AppSettings.empty);

    expect(File('${file.path}.tmp').existsSync(), isFalse);
    expect(file.statSync().mode & 0x1FF, 0x180);
  }, skip: Platform.isWindows);
}
