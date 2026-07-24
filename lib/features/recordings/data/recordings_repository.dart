import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/capture_type.dart';
// Prefixed so the class-level `extensionFor` below can delegate to the domain
// policy instead of recursing into itself.
import '../domain/capture_type.dart' as policy;
import '../domain/recording.dart';

class RecordingsRepository {
  /// Storage-policy surface: which extension an item of [type] is stored under.
  /// Delegates to the single definition in `capture_type.dart`, and names the
  /// parameter after the `Recording.sourceMimeType` field it is fed from.
  static String extensionFor(CaptureType type, {String? sourceMimeType}) =>
      policy.extensionFor(type, mimeType: sourceMimeType);

  Future<Directory> recordingsDirectory() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    final Directory directory = Directory(p.join(appDirectory.path, 'recordings'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// Path for an item's source artifact: `<id>.<extension>` in the recordings
  /// directory. The file is not created here — callers write it and verify a
  /// non-zero length before the item is ever indexed.
  Future<File> createSourceFile(String id, String extension) async {
    final Directory directory = await recordingsDirectory();
    return File(p.join(directory.path, '$id.$extension'));
  }

  /// Convenience over [createSourceFile] using the per-type extension policy.
  Future<File> createSourceFileFor(
    String id,
    CaptureType type, {
    String? mimeType,
  }) =>
      createSourceFile(id, policy.extensionFor(type, mimeType: mimeType));

  /// Mic-capture path, unchanged.
  Future<File> createAudioFile(String id) => createSourceFile(id, 'm4a');

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
