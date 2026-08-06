import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../../projects/data/projects_repository.dart';
import '../../projects/domain/project.dart';
import '../../recordings/data/recordings_repository.dart';
import '../../recordings/domain/recording.dart';
import '../domain/capture_archive.dart';

typedef ArchiveDirectoryProvider = Future<Directory> Function();

/// A zip of the recordings directory, merged back in additively.
///
/// The layout inside the archive is **flat and identical to the directory it
/// came from**, which is deliberate: a user who never runs the import — because
/// the phone is gone, or the app will not start — restores by unzipping into
/// the recordings folder by hand. An archive that only this class can apply
/// would be a second way to lose the data it was taken to protect.
class ZipCaptureArchive implements CaptureArchive {
  ZipCaptureArchive({
    required ArchiveDirectoryProvider directoryProvider,
    RecordingsRepository? recordings,
    ProjectsRepository? projects,
  }) : _directoryProvider = directoryProvider,
       _recordings = recordings ?? RecordingsRepository(),
       _projects =
           projects ?? ProjectsRepository(directoryProvider: directoryProvider);

  final ArchiveDirectoryProvider _directoryProvider;
  final RecordingsRepository _recordings;
  final ProjectsRepository _projects;

  static const String manifestName = 'capture-archive.json';
  static const int formatVersion = 1;

  /// Merged row by row on import, because both are keyed collections whose
  /// local copy has moved on since the archive was taken.
  static const Set<String> indexFiles = <String>{
    'recordings.json',
    'projects.json',
  };

  /// Merged line by line: append-only stores where a line is the whole record.
  static const Set<String> journalFiles = <String>{
    'revisions.jsonl',
    'focus-sessions.jsonl',
  };

  /// Never archived.
  ///
  /// `settings.json` carries provider bearer tokens sealed under a keyring
  /// master key that does not travel — exporting them leaks secrets that would
  /// not even decrypt at the destination. `logs.json` is a capped debug ring
  /// buffer, not history. `gamification.json` is engagement state; merging two
  /// streaks has no right answer, and inventing one is worse than asking the
  /// user to carry on from where the counter now stands.
  static const Set<String> excludedFiles = <String>{
    'settings.json',
    'logs.json',
    'gamification.json',
  };

  /// Timestamped copies the repositories drop when something has gone wrong.
  /// They are diagnostics of a past failure, and shipping them into a fresh
  /// install would re-import the very rows a backup was made to escape.
  static bool isDiagnosticCopy(String name) =>
      name.endsWith('.tmp') ||
      name.contains('.corrupt-') ||
      name.contains('.partial-') ||
      name.contains('.shrank-');

  static bool _isPayload(String name) =>
      !excludedFiles.contains(name) &&
      !isDiagnosticCopy(name) &&
      !name.endsWith('.thumb.jpg') &&
      name != manifestName;

  @override
  Future<BackupSummary> exportTo(File destination) async {
    final Directory directory = await _directoryProvider();
    final List<File> members = <File>[];
    if (await directory.exists()) {
      await for (final FileSystemEntity entity in directory.list()) {
        if (entity is! File) continue;
        if (_isPayload(p.basename(entity.path))) members.add(entity);
      }
    }
    // Stable order so two exports of an unchanged queue differ only by the
    // timestamp in the manifest, which makes them diffable by hand.
    members.sort((File a, File b) => a.path.compareTo(b.path));

    final int captures = await _countCaptures(directory);
    final List<Map<String, Object>> manifestFiles = <Map<String, Object>>[];
    for (final File member in members) {
      manifestFiles.add(<String, Object>{
        'name': p.basename(member.path),
        'size': await member.length(),
      });
    }

    final ZipFileEncoder encoder = ZipFileEncoder();
    // Streamed to disk rather than built in memory: an archive is mostly audio,
    // and a year of captures is not a thing to hold in RAM to hand to a picker.
    encoder.create(destination.path);
    try {
      encoder.addArchiveFile(
        ArchiveFile.string(
          manifestName,
          const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
            'format': formatVersion,
            'createdAt': DateTime.now().toIso8601String(),
            'captures': captures,
            'files': manifestFiles,
          }),
        ),
      );
      for (final File member in members) {
        await encoder.addFile(member, p.basename(member.path));
      }
    } finally {
      // Closed even on failure: a half-written zip left open would keep its
      // handle and report a size that is not what is on disk.
      await encoder.close();
    }

    return BackupSummary(
      captures: captures,
      files: members.length + 1,
      bytes: await destination.length(),
      destination: destination.path,
    );
  }

  @override
  Future<RestoreSummary> importFrom(File source) async {
    if (!await source.exists()) {
      throw ArchiveUnreadableException(source.path, 'the file is not there');
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(InputFileStream(source.path));
    } catch (exception) {
      throw ArchiveUnreadableException(source.path, '$exception');
    }
    _validateManifest(archive, source.path);

    final Directory directory = await _directoryProvider();
    if (!await directory.exists()) await directory.create(recursive: true);

    final _RecordingImportPlan plan = await _planRecordings(archive, directory);

    // **Files before rows.** A row pointing at a file that is not there is a
    // capture with nothing behind it and no way back; a file with no row is an
    // orphan, and `recoverOrphans()` already walks those into the queue. The
    // order is chosen so a failure lands in the recoverable half.
    await _restoreSources(archive, directory, plan);

    for (final String name in journalFiles) {
      await _mergeJournal(archive, directory, name);
    }
    await _mergeProjects(archive);
    return _commitRecordings(plan);
  }

  /// Validate the whole archive contract before writing a byte into the app's
  /// directory. File sizes make a truncated member distinguishable from a
  /// valid empty library, while an explicit format refusal prevents a newer
  /// archive from being half-understood by an older build.
  void _validateManifest(Archive archive, String sourcePath) {
    final ArchiveFile? entry = archive.findFile(manifestName);
    if (entry == null) {
      throw ArchiveUnreadableException(
        sourcePath,
        'no $manifestName inside — this is not a capture archive',
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(entry.readBytes() ?? <int>[]));
    } catch (exception) {
      throw ArchiveUnreadableException(
        manifestName,
        'the manifest is not JSON: $exception',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ArchiveUnreadableException(
        manifestName,
        'the manifest is not an object',
      );
    }
    if (decoded['format'] != formatVersion) {
      throw ArchiveUnreadableException(
        manifestName,
        'unsupported format ${decoded['format']} (this build reads $formatVersion)',
      );
    }
    final Object? rawFiles = decoded['files'];
    if (rawFiles is! List<dynamic>) {
      throw const ArchiveUnreadableException(
        manifestName,
        'the manifest has no file inventory',
      );
    }

    final Set<String> seen = <String>{};
    for (final dynamic raw in rawFiles) {
      if (raw is! Map<String, dynamic> ||
          raw['name'] is! String ||
          raw['size'] is! int) {
        throw const ArchiveUnreadableException(
          manifestName,
          'the file inventory contains an unreadable row',
        );
      }
      final String name = raw['name'] as String;
      final int size = raw['size'] as int;
      if (name.isEmpty ||
          p.basename(name) != name ||
          size < 0 ||
          !seen.add(name)) {
        throw ArchiveUnreadableException(
          manifestName,
          'invalid or duplicate file inventory entry: $name',
        );
      }
      final ArchiveFile? member = archive.findFile(name);
      if (member == null ||
          !member.isFile ||
          member.isSymbolicLink ||
          member.size != size) {
        throw ArchiveUnreadableException(
          name,
          'missing or truncated (expected $size bytes)',
        );
      }
    }
    for (final ArchiveFile member in archive) {
      final String name = p.basename(member.name);
      if (member.name != name || member.isSymbolicLink) {
        throw ArchiveUnreadableException(
          member.name,
          'archive members must be flat regular files',
        );
      }
      if (member.isFile && _isPayload(name) && !seen.contains(name)) {
        throw ArchiveUnreadableException(
          manifestName,
          'archive member is missing from the file inventory: $name',
        );
      }
    }
  }

  /// Decide which archived rows are additions before extracting their files.
  /// Hashes are compared only with the library that existed before this import:
  /// two deliberate duplicate captures inside one archive therefore remain two
  /// rows, while importing either one onto a device that already has the bytes
  /// skips it.
  Future<_RecordingImportPlan> _planRecordings(
    Archive archive,
    Directory directory,
  ) async {
    final ArchiveFile? entry = archive.findFile('recordings.json');
    final List<Recording> local = await _recordings.loadAll();
    final _RecordingImportPlan plan = _RecordingImportPlan(local);
    if (entry == null) {
      return plan;
    }

    // Throws IndexUnreadableException if the *local* index is broken, and that
    // is the right outcome: merging into an index we cannot read would write a
    // partial list over real history — the exact failure this app is hardened
    // against. Refusing to import is the recoverable answer.
    final Set<String> localIds = local.map((Recording item) => item.id).toSet();
    final Set<String> localHashes = local
        .map((Recording item) => item.contentHash)
        .whereType<String>()
        .toSet();
    final Set<String> acceptedIds = <String>{};

    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(entry.readBytes() ?? <int>[]));
    } catch (exception) {
      throw ArchiveUnreadableException(
        'recordings.json',
        'the archived index is not JSON: $exception',
      );
    }
    if (decoded is! List<dynamic>) {
      throw const ArchiveUnreadableException(
        'recordings.json',
        'the archived index is not a list',
      );
    }

    for (final dynamic row in decoded) {
      final Recording incoming;
      try {
        incoming = Recording.fromJson(row as Map<String, dynamic>);
      } catch (_) {
        // Per-row degradation, the same rule `loadAll` applies: one bad row
        // must not cost the rest of the archive.
        plan.unreadable++;
        continue;
      }
      final bool sameLocalBytes =
          incoming.contentHash != null &&
          localHashes.contains(incoming.contentHash);
      if (localIds.contains(incoming.id) || sameLocalBytes) {
        // The local copy has been edited, enriched and possibly routed since
        // the archive was taken. The archived one is older by definition, so
        // it never wins — a restore must not be able to undo work.
        plan.alreadyPresent++;
        continue;
      }
      if (!acceptedIds.add(incoming.id)) {
        plan.unreadable++;
        continue;
      }
      final String sourceName = p.basename(incoming.filePath);
      final ArchiveFile? source = archive.findFile(sourceName);
      final bool conventionalName =
          p.basenameWithoutExtension(sourceName) == incoming.id &&
          _isPayload(sourceName) &&
          !indexFiles.contains(sourceName) &&
          !journalFiles.contains(sourceName);
      if (!conventionalName ||
          source == null ||
          !source.isFile ||
          source.isSymbolicLink ||
          source.size <= 0) {
        plan.unreadable++;
        continue;
      }
      plan.additions.add(_relocate(incoming, directory));
    }
    return plan;
  }

  /// Extract only sources whose rows survived the deduplication plan. Writing
  /// through a temporary file prevents a failed unzip from leaving a partial
  /// source under the final capture name.
  Future<void> _restoreSources(
    Archive archive,
    Directory directory,
    _RecordingImportPlan plan,
  ) async {
    final List<Recording> restored = <Recording>[];
    for (final Recording item in plan.additions) {
      final String name = p.basename(item.filePath);
      final ArchiveFile entry = archive.findFile(name)!;
      final File target = File(p.join(directory.path, name));
      if (await target.exists()) {
        // A source without an index row is recoverable and may be valuable.
        // Never overwrite it or point an imported row at unknown bytes.
        plan.unreadable++;
        continue;
      }
      final File temporary = File('${target.path}.importing');
      final OutputFileStream output = OutputFileStream(temporary.path);
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
      if (!await temporary.exists() || await temporary.length() != entry.size) {
        if (await temporary.exists()) await temporary.delete();
        throw ArchiveUnreadableException(
          name,
          'extracted size did not match ${entry.size} bytes',
        );
      }
      await temporary.rename(target.path);
      restored.add(item);
      plan.filesRestored++;
    }
    plan.additions
      ..clear()
      ..addAll(restored);
  }

  Future<RestoreSummary> _commitRecordings(_RecordingImportPlan plan) async {
    if (plan.additions.isNotEmpty) {
      final List<Recording> merged = <Recording>[
        ...plan.local,
        ...plan.additions,
      ]..sort((Recording a, Recording b) => b.createdAt.compareTo(a.createdAt));
      await _recordings.saveAll(merged);
    }
    return RestoreSummary(
      added: plan.additions.length,
      alreadyPresent: plan.alreadyPresent,
      unreadable: plan.unreadable,
      filesRestored: plan.filesRestored,
    );
  }

  /// Absolute paths do not survive the trip. The archive was taken from another
  /// container, another user account, or another operating system, so every
  /// stored path points nowhere here — only the file *name* is portable, and it
  /// is `<id>.<ext>` by construction.
  ///
  /// Rebuilt field by field rather than through `copyWith`, which deliberately
  /// offers no `filePath`: a capture's source is immutable once written, and
  /// this is the one place that is not a mutation but a re-pointing at the same
  /// bytes in a new home. Widening `copyWith` for it would hand every caller a
  /// way to detach a row from its file.
  Recording _relocate(Recording recording, Directory directory) {
    return Recording(
      id: recording.id,
      filePath: p.join(directory.path, p.basename(recording.filePath)),
      createdAt: recording.createdAt,
      durationMs: recording.durationMs,
      status: recording.status,
      sizeBytes: recording.sizeBytes,
      contentHash: recording.contentHash,
      type: recording.type,
      sourceMimeType: recording.sourceMimeType,
      transcript: recording.transcript,
      // Posters are derived and intentionally excluded from the archive; the
      // normal startup backfill recreates one for restored videos.
      thumbPath: null,
      title: recording.title,
      category: recording.category,
      summary: recording.summary,
      tags: recording.tags,
      projectId: recording.projectId,
      error: recording.error,
      isProcessedByUser: recording.isProcessedByUser,
      processedAt: recording.processedAt,
      routes: recording.routes,
    );
  }

  Future<void> _mergeProjects(Archive archive) async {
    final ArchiveFile? entry = archive.findFile('projects.json');
    if (entry == null) return;

    final List<Project> local = await _projects.loadAll();
    final String? activeId = _projects.loadedActiveProjectId;
    final Set<String> known = local.map((Project item) => item.id).toSet();

    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(entry.readBytes() ?? <int>[]));
    } catch (_) {
      // Projects are supporting context, not the capture. A malformed archived
      // list costs the projects and never the recordings — same rule the
      // controller applies to a revision history that will not load.
      return;
    }
    final dynamic rows = decoded is Map<String, dynamic>
        ? decoded['projects']
        : decoded;
    if (rows is! List<dynamic>) return;

    final List<Project> merged = List<Project>.from(local);
    bool changed = false;
    for (final dynamic row in rows) {
      try {
        final Project incoming = Project.fromJson(row as Map<String, dynamic>);
        if (known.contains(incoming.id)) continue;
        merged.add(incoming);
        known.add(incoming.id);
        changed = true;
      } catch (_) {
        continue;
      }
    }
    // The active selection is this install's, not the archive's: importing a
    // backup must not silently repoint which project new captures inherit.
    if (changed) await _projects.saveAll(merged, activeProjectId: activeId);
  }

  /// Append-only stores merge as a set of lines.
  ///
  /// A revision and a finished focus session are each a whole record on one
  /// line with no id to key on, so exact-line identity is the only honest
  /// comparison available — and it is the right one: two identical lines *are*
  /// the same event, because both carry their own timestamp.
  Future<void> _mergeJournal(
    Archive archive,
    Directory directory,
    String name,
  ) async {
    final ArchiveFile? entry = archive.findFile(name);
    if (entry == null) return;

    final List<int>? bytes = entry.readBytes();
    if (bytes == null) return;
    final List<String> incoming = const LineSplitter()
        .convert(utf8.decode(bytes, allowMalformed: true))
        .where((String line) => line.trim().isNotEmpty)
        .toList();
    if (incoming.isEmpty) return;

    final File target = File(p.join(directory.path, name));
    final Set<String> existing = await target.exists()
        ? const LineSplitter().convert(await target.readAsString()).toSet()
        : <String>{};

    final List<String> fresh = incoming
        .where((String line) => !existing.contains(line))
        .toList();
    if (fresh.isEmpty) return;

    // Appended, never rewritten — the same rule these files already live by,
    // and the reason a restore cannot destroy the history it is restoring.
    await target.writeAsString(
      '${fresh.join('\n')}\n',
      mode: FileMode.writeOnlyAppend,
      flush: true,
    );
  }

  /// Read straight off the file rather than through `loadAll`, so an index this
  /// build cannot parse still gets archived — with an honest count of zero —
  /// instead of blocking the backup that would preserve it.
  Future<int> _countCaptures(Directory directory) async {
    try {
      final File index = File(p.join(directory.path, 'recordings.json'));
      if (!await index.exists()) return 0;
      final dynamic decoded = jsonDecode(await index.readAsString());
      return decoded is List<dynamic> ? decoded.length : 0;
    } catch (_) {
      return 0;
    }
  }
}

class _RecordingImportPlan {
  _RecordingImportPlan(this.local);

  final List<Recording> local;
  final List<Recording> additions = <Recording>[];
  int alreadyPresent = 0;
  int unreadable = 0;
  int filesRestored = 0;
}
