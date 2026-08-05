import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/gamification_stats.dart';

class GamificationRepository {
  Future<Directory> _directory() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    final Directory directory = Directory(
      p.join(appDirectory.path, 'recordings'),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> _file() async {
    final Directory directory = await _directory();
    return File(p.join(directory.path, 'gamification.json'));
  }

  Future<GamificationStats> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) {
        return const GamificationStats();
      }

      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const GamificationStats();
      }

      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const GamificationStats();
      }
      return GamificationStats.fromJson(decoded);
    } catch (_) {
      return const GamificationStats();
    }
  }

  Future<void> save(GamificationStats stats) async {
    try {
      final File file = await _file();
      final String payload =
          const JsonEncoder.withIndent('  ').convert(stats.toJson());

      final File temporary = File('${file.path}.tmp');
      await temporary.writeAsString(payload, flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      // Best effort persist
    }
  }
}
