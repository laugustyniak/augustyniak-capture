import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../projects/data/projects_repository.dart';
import '../../projects/domain/project.dart';
import '../../recordings/data/recordings_repository.dart';
import '../../recordings/data/source_content_hasher.dart';
import '../../recordings/domain/capture_segment.dart';
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
    SourceContentHasher hasher = const SourceContentHasher(),
  }) : _directoryProvider = directoryProvider,
       _hasher = hasher,
       _recordings = recordings ?? RecordingsRepository(),
       _projects =
           projects ?? ProjectsRepository(directoryProvider: directoryProvider);

  /// Fired once the manifest is computed and before any member is written.
  ///
  /// A test-only seam, and the only way to reach the failure this ordering was
  /// changed for: the live app rewrites a durable index *during* a compression
  /// pass that takes minutes, which no test can schedule and no clock-based
  /// wait may stand in for. Null in production, so the export reads as one
  /// straight line there.
  @visibleForTesting
  Future<void> Function()? onManifestSealed;

  final ArchiveDirectoryProvider _directoryProvider;
  final SourceContentHasher _hasher;
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
  ///
  /// All three of the repo's append-only stores belong here. `closures.jsonl`
  /// was missing while it was still being *exported* as a payload member, so a
  /// restore silently dropped the momentum history — the file that exists
  /// precisely because no other store can answer "how many did I close last
  /// Tuesday". A store that travels in the archive and is never merged back is
  /// worse than one left out of it: the bytes are carried and then discarded.
  static const Set<String> journalFiles = <String>{
    'revisions.jsonl',
    'focus-sessions.jsonl',
    'closures.jsonl',
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
      // Staging file for a source being extracted. A failed import used to
      // leave one behind, and without this the next export shipped it.
      name.endsWith('.importing') ||
      name.contains('.corrupt-') ||
      name.contains('.partial-') ||
      name.contains('.shrank-');

  /// Members the live app rewrites underneath an export in progress. Everything
  /// else in the payload is a capture's source, whose bytes never change once
  /// written.
  static bool _isMutable(String name) =>
      indexFiles.contains(name) || journalFiles.contains(name);

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

    // **The manifest must describe the bytes that were archived, not the bytes
    // that were on disk when it was written.** `_validateManifest` refuses the
    // whole archive on a size mismatch, so measuring with `length()` and then
    // handing the encoder the *file* leaves a window the live app walks
    // straight into: the durable indexes are rewritten on every pipeline tick,
    // and a status transition landing during a compression pass that takes
    // minutes produced an archive rejected at import time — on the far end,
    // when the user has nothing else to fall back on.
    //
    // Mutable members are therefore snapshotted once and archived from that
    // snapshot. Only the indexes and journals qualify, and they are small; a
    // capture's source bytes are immutable once written, so those keep
    // streaming and the archive stays out of RAM.
    final Map<String, List<int>> snapshots = <String, List<int>>{};
    final List<Map<String, Object>> manifestFiles = <Map<String, Object>>[];
    for (final File member in members) {
      final String name = p.basename(member.path);
      final int size;
      if (_isMutable(name)) {
        final List<int> bytes = await member.readAsBytes();
        snapshots[name] = bytes;
        size = bytes.length;
      } else {
        size = await member.length();
      }
      manifestFiles.add(<String, Object>{'name': name, 'size': size});
    }

    await onManifestSealed?.call();

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
        final String name = p.basename(member.path);
        final List<int>? snapshot = snapshots[name];
        if (snapshot != null) {
          encoder.addArchiveFile(ArchiveFile.bytes(name, snapshot));
        } else {
          await encoder.addFile(member, name);
        }
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
    try {
      return await _importFrom(archive, source);
    } finally {
      // `decodeStream` holds the zip open through an `InputFileStream`, and
      // nothing above ever released it: every import leaked a descriptor for
      // the life of the process, and on Windows kept the user's chosen file
      // locked against rename or delete.
      archive.clearSync();
    }
  }

  Future<RestoreSummary> _importFrom(Archive archive, File source) async {
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

    // **Recordings commit before the projects merge, not after.** The rule this
    // class states for projects — a projects failure costs the projects and
    // never the recordings — was not what the order delivered: `_mergeProjects`
    // reads the *local* `projects.json`, which throws on a malformed one, and
    // running it first meant a broken projects file aborted the whole restore
    // after every source file had been written and before a single row was.
    final RestoreSummary summary = await _commitRecordings(plan);
    await _mergeProjects(archive);
    return summary;
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
      final bool sameId = localIds.contains(incoming.id);
      if (sameId || sameLocalBytes) {
        // The local copy has been edited, enriched and possibly routed since
        // the archive was taken. The archived one is older by definition, so
        // it never wins — a restore must not be able to undo work.
        plan.alreadyPresent++;
        // Recorded, not swallowed: an id match only proves this archive came
        // from this library, while a hash match proves the bytes are the same
        // wherever they were captured. An archive predating `contentHash`
        // restores looking fully deduplicated having compared nothing.
        if (!sameLocalBytes) plan.matchedByIdAlone++;
        continue;
      }
      if (!acceptedIds.add(incoming.id)) {
        plan.unreadable++;
        continue;
      }
      // Every segment, not just segment 0. A row whose fragment is missing is
      // refused whole rather than restored pointing at a file that is not
      // there — the same all-or-nothing rule the extraction below follows.
      bool everyMemberPresent = true;
      for (final CaptureSegment segment in incoming.segments) {
        final String name = p.basename(segment.filePath);
        final ArchiveFile? member = archive.findFile(name);
        final String stem = p.basenameWithoutExtension(name);
        final bool conventionalName =
            (stem == incoming.id ||
                stem == '${incoming.id}-${segment.index}') &&
            _isPayload(name) &&
            !indexFiles.contains(name) &&
            !journalFiles.contains(name);
        if (!conventionalName ||
            member == null ||
            !member.isFile ||
            member.isSymbolicLink ||
            member.size <= 0) {
          everyMemberPresent = false;
          break;
        }
      }
      if (!everyMemberPresent) {
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
      // A row counts as restored only when every one of its members landed.
      // Half a capture is worse than none: the index would claim text the
      // missing fragment produced, pointing at a file nothing can read.
      bool everyMemberLanded = true;
      for (final CaptureSegment segment in item.segments) {
        final String name = p.basename(segment.filePath);
        final ArchiveFile entry = archive.findFile(name)!;
        final File target = File(p.join(directory.path, name));
        if (await target.exists()) {
          // **An import that failed part-way must stay retryable.** Nothing is
          // committed unless every file lands, so a throw on the tenth capture
          // leaves the first nine extracted and no rows written. Refusing every
          // pre-existing file on the retry would then drop those nine rows for
          // good — their sources survive as orphans `recoverOrphans()` re-adopts,
          // but the transcripts, which only ever lived in the index, do not.
          //
          // So a file that *is* the archived one counts as already extracted and
          // keeps its row. Anything else is still refused: a source with no index
          // row may be the user's own and is never overwritten, and an imported
          // row must never be pointed at unknown bytes.
          if (await _isSameSource(target, entry, segment.contentHash)) {
            continue;
          }
          everyMemberLanded = false;
          break;
        }
        final File temporary = File('${target.path}.importing');
        try {
          final OutputFileStream output = OutputFileStream(temporary.path);
          try {
            entry.writeContent(output);
          } finally {
            output.closeSync();
          }
          if (!await temporary.exists() ||
              await temporary.length() != entry.size) {
            throw ArchiveUnreadableException(
              name,
              'extracted size did not match ${entry.size} bytes',
            );
          }
        } catch (_) {
          // Every failure path clears the staging file, not just the size
          // mismatch. A leftover `.importing` is a payload member `_isPayload`
          // would otherwise ship in the next export.
          if (await temporary.exists()) await temporary.delete();
          rethrow;
        }
        await temporary.rename(target.path);
        plan.filesRestored++;
      }
      if (everyMemberLanded) {
        restored.add(item);
      } else {
        plan.unreadable++;
      }
    }
    plan.additions
      ..clear()
      ..addAll(restored);
  }

  /// Whether the file already on disk is the one this archive carries.
  ///
  /// Size first, because it is a `stat` and settles almost every case. The hash
  /// is only consulted when the incoming row has one — legacy rows do not — and
  /// only after the size matched, so a full read of a long video happens only
  /// on the retry of a failed import, never on a first one. Name equality is
  /// itself strong evidence: sources are `<capture-id>.<ext>` and the id is a
  /// uuid, so a collision means the same capture.
  Future<bool> _isSameSource(
    File target,
    ArchiveFile entry,
    String? expectedHash,
  ) async {
    try {
      if (await target.length() != entry.size) return false;
      final String? expected = expectedHash;
      if (expected == null) return true;
      return await _hasher.hash(target) == expected;
    } catch (_) {
      // A file that cannot be measured is not one to claim as ours.
      return false;
    }
  }

  Future<RestoreSummary> _commitRecordings(_RecordingImportPlan plan) async {
    if (plan.additions.isNotEmpty) {
      // **Merged against the index as it is now, not against `plan.local`.**
      // That snapshot was taken before the source files were extracted, and
      // extraction is the slow part: a capture indexed while it ran is present
      // on disk and in `recordings.json`, and writing the older merge over it
      // would drop the row. `updateAll` holds the repository's write gate
      // across the reload, the merge and the write, so nothing lands in
      // between — and the same gate is what stops this write from tearing the
      // shared `.tmp` against a concurrent pipeline save.
      //
      // Ids already present are skipped rather than replaced, which is the
      // additive rule this class is built on: the local row may have been
      // edited, enriched and routed since, and the archived one is older by
      // definition.
      await _recordings.updateAll((List<Recording> current) async {
        final Set<String> present = current
            .map((Recording item) => item.id)
            .toSet();
        return <Recording>[
          ...current,
          ...plan.additions.where(
            (Recording item) => !present.contains(item.id),
          ),
        ]..sort(
          (Recording a, Recording b) => b.createdAt.compareTo(a.createdAt),
        );
      });
    }
    return RestoreSummary(
      added: plan.additions.length,
      alreadyPresent: plan.alreadyPresent,
      matchedByIdAlone: plan.matchedByIdAlone,
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
      artifacts: recording.artifacts,
      // Left null for a row that never gained a fragment, so it keeps
      // serialising without a `segments` key exactly as it arrived.
      segments: recording.hasStoredSegments
          ? <CaptureSegment>[
              for (final CaptureSegment segment in recording.segments)
                CaptureSegment(
                  index: segment.index,
                  filePath: p.join(
                    directory.path,
                    p.basename(segment.filePath),
                  ),
                  type: segment.type,
                  sourceMimeType: segment.sourceMimeType,
                  createdAt: segment.createdAt,
                  durationMs: segment.durationMs,
                  sizeBytes: segment.sizeBytes,
                  contentHash: segment.contentHash,
                  text: segment.text,
                  error: segment.error,
                ),
            ]
          : null,
    );
  }

  Future<void> _mergeProjects(Archive archive) async {
    final ArchiveFile? entry = archive.findFile('projects.json');
    if (entry == null) return;

    final List<Project> local;
    try {
      local = await _projects.loadAll();
    } catch (_) {
      // A local `projects.json` this build cannot read throws out of `loadAll`.
      // Merging into a list we cannot see would either drop the user's projects
      // or duplicate them, so the archived list is left where it is — the
      // captures, which are the point of the restore, are already committed.
      return;
    }
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

    // These files are documented as able to end mid-record after a kill, and
    // `load` absorbs that by skipping the one torn line. Appending straight
    // onto it would fuse the fresh first record to the partial one and cost
    // both, so the separator is restored first when it is missing.
    final bool needsSeparator =
        await target.exists() &&
        await target.length() > 0 &&
        !(await target.readAsString()).endsWith('\n');

    // Appended, never rewritten — the same rule these files already live by,
    // and the reason a restore cannot destroy the history it is restoring.
    await target.writeAsString(
      '${needsSeparator ? '\n' : ''}${fresh.join('\n')}\n',
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
  int matchedByIdAlone = 0;
  int unreadable = 0;
  int filesRestored = 0;
}
