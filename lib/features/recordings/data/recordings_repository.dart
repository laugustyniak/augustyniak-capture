import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/recording.dart';

class RecordingsRepository {
  Future<Directory> recordingsDirectory() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    final Directory directory = Directory(p.join(appDirectory.path, 'recordings'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> createAudioFile(String id) async {
    final Directory directory = await recordingsDirectory();
    return File(p.join(directory.path, '$id.m4a'));
  }

  Future<List<Recording>> loadAll() async {
    final File index = await _indexFile();
    if (!await index.exists()) {
      return <Recording>[];
    }

    final String raw = await index.readAsString();
    if (raw.trim().isEmpty) {
      return <Recording>[];
    }

    final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
    final List<Recording> recordings = decoded
        .map((dynamic item) => Recording.fromJson(item as Map<String, dynamic>))
        .toList();
    recordings.sort((Recording a, Recording b) => b.createdAt.compareTo(a.createdAt));
    return recordings;
  }

  Future<void> saveAll(List<Recording> recordings) async {
    final File index = await _indexFile();
    final String payload = const JsonEncoder.withIndent('  ')
        .convert(recordings.map((Recording item) => item.toJson()).toList());

    final File temporary = File('${index.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    await temporary.rename(index.path);
  }

  Future<File> _indexFile() async {
    final Directory directory = await recordingsDirectory();
    return File(p.join(directory.path, 'recordings.json'));
  }
}
