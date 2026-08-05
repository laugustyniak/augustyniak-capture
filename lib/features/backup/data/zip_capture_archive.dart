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
    if (archive.findFile(manifestName) == null) {
      throw ArchiveUnreadableException(
        source.path,
        'no $manifestName inside — this is not a capture archive',
      );
    }

    final Directory directory = await _directoryProvider();
    if (!await directory.exists()) await directory.create(recursive: true);

    // **Files before rows.** A row pointing at a file that is not there is a
    // capture with nothing behind it and no way back; a file with no row is an
    // orphan, and `recoverOrphans()` already walks those into the queue. The
    // order is chosen so a failure lands in the recoverable half.
    int filesRestored = 0;
    for (final ArchiveFile entry in archive) {
      final String name = p.basename(entry.name);
      if (!entry.isFile) continue;
      if (!_isPayload(name)) continue;
      if (indexFiles.contains(name) || journalFiles.contains(name)) continue;

      final File target = File(p.join(directory.path, name));
      // Never overwrite: the local copy is the one the queue is pointing at,
      // and a source artifact is immutable once captured anyway.
      if (await target.exists()) continue;
      final List<int>? bytes = entry.readBytes();
      if (bytes == null) continue;
      await target.writeAsBytes(bytes, flush: true);
      filesRestored++;
    }

    for (final String name in journalFiles) {
      await _mergeJournal(archive, directory, name);
    }
    await _mergeProjects(archive);
    return _mergeRecordings(archive, directory, filesRestored);
  }

  /// Rows the archive holds that the local index does not, with their paths
  /// re-pointed at this install's recordings directory.
  Future<RestoreSummary> _mergeRecordings(
    Archive archive,
    Directory directory,
    int filesRestored,
  ) async {
    final ArchiveFile? entry = archive.findFile('recordings.json');
    if (entry == null) {
      return RestoreSummary(
        added: 0,
        alreadyPresent: 0,
        unreadable: 0,
        filesRestored: filesRestored,
      );
    }

    // Throws IndexUnreadableException if the *local* index is broken, and that
    // is the right outcome: merging into an index we cannot read would write a
    // partial list over real history — the exact failure this app is hardened
    // against. Refusing to import is the recoverable answer.
    final List<Recording> local = await _recordings.loadAll();
    final Set<String> known = local.map((Recording item) => item.id).toSet();

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

    int added = 0;
    int alreadyPresent = 0;
    int unreadable = 0;
    final List<Recording> merged = List<Recording>.from(local);
    for (final dynamic row in decoded) {
      final Recording incoming;
      try {
        incoming = Recording.fromJson(row as Map<String, dynamic>);
      } catch (_) {
        // Per-row degradation, the same rule `loadAll` applies: one bad row
        // must not cost the rest of the archive.
        unreadable++;
        continue;
      }
      if (known.contains(incoming.id)) {
        // The local copy has been edited, enriched and possibly routed since
        // the archive was taken. The archived one is older by definition, so
        // it never wins — a restore must not be able to undo work.
        alreadyPresent++;
        continue;
      }
      merged.add(_relocate(incoming, directory));
      known.add(incoming.id);
      added++;
    }

    if (added > 0) {
      merged.sort(
        (Recording a, Recording b) => b.createdAt.compareTo(a.createdAt),
      );
      await _recordings.saveAll(merged);
    }
    return RestoreSummary(
      added: added,
      alreadyPresent: alreadyPresent,
      unreadable: unreadable,
      filesRestored: filesRestored,
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
      type: recording.type,
      sourceMimeType: recording.sourceMimeType,
      transcript: recording.transcript,
      thumbPath: recording.thumbPath == null
          ? null
          : p.join(directory.path, p.basename(recording.thumbPath!)),
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
