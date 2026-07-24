import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/app_settings.dart';

/// Persists `settings.json` next to `recordings.json`, using the same atomic
/// write (`.tmp` then `rename`) so a crash mid-write cannot truncate settings.
class SettingsRepository {
  Future<Directory> _directory() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    final Directory directory =
        Directory(p.join(appDirectory.path, 'recordings'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> settingsFile() async {
    final Directory directory = await _directory();
    return File(p.join(directory.path, 'settings.json'));
  }

  Future<AppSettings?> load() async {
    final File file = await settingsFile();
    if (!await file.exists()) {
      return null;
    }

    final String raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return null;
    }

    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    return AppSettings.fromJson(decoded);
  }

  Future<void> save(AppSettings settings) async {
    final File file = await settingsFile();
    final String payload =
        const JsonEncoder.withIndent('  ').convert(settings.toJson());

    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    await temporary.rename(file.path);
  }
}
