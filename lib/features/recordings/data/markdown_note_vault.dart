import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../domain/capture_type.dart';
import '../domain/note_vault.dart';
import '../domain/untrusted_markdown.dart';

/// Mirrors every capture into a directory the user owns — an Obsidian vault,
/// a synced folder, a plain notes repository — as one markdown file per note,
/// with the enriched title, category and tags carried in YAML front matter.
///
/// **The vault is not ours, and every rule here follows from that.** It is the
/// same premise as `ProjectInboxRouter`'s `inbox.md`, one step further: the
/// reader does not merely edit these files, their application indexes them,
/// links them and reorders lists by their modification time. So:
///
/// - **A note is located by id, never by name.** The file name carries the id's
///   first eight characters as a suffix; the rest of it is decoration. That is
///   what lets a title arrive from enrichment after the file already exists.
/// - **The name is then never changed again.** Renaming a file behind the
///   reader's back would break every `[[wikilink]]` they had written to it, and
///   nothing in this app could repair them. A later title lands in the front
///   matter and the heading, where it is the same information without the cost.
/// - **A file is only rewritten while it is still ours.** `capture-hash` in the
///   front matter is the sha-256 of the body beneath it; a mismatch means the
///   reader has edited the note, and the mirror steps back and reports
///   [VaultOutcome.foreign] instead. The claim lives *in the file* rather than
///   in `recordings.json` on purpose — a vault rebuilt after a reinstall then
///   still knows which notes it owns, and no persisted type needed a new field.
/// - **An unchanged note is not rewritten at all.** A no-op write would still
///   bump the mtime and push the note to the top of the reader's "recent" list
///   on every unrelated pipeline tick.
class MarkdownNoteVault implements NoteVault {
  MarkdownNoteVault({
    required String? Function() vaultPath,
    String Function() folder = _defaultFolder,
    bool Function() copySources = _copyByDefault,
    String? Function(String projectId) projectName = _noProjectName,
  }) : _vaultPath = vaultPath,
       _folder = folder,
       _copySources = copySources,
       _projectName = projectName;

  /// Read through callbacks rather than captured, for the same reason
  /// `ProjectInboxRouter` looks its projects up live: the shell builds this once
  /// and the user can point it somewhere else at any time afterwards.
  final String? Function() _vaultPath;
  final String Function() _folder;
  final bool Function() _copySources;

  /// Null for an unknown id — a project deleted after the capture was filed
  /// leaves a dangling reference, the same shape as a dangling profile id. The
  /// note then simply carries no project, rather than an id nobody can read.
  final String? Function(String projectId) _projectName;

  static String _defaultFolder() => VaultDefaults.folder;
  static bool _copyByDefault() => true;
  static String? _noProjectName(String projectId) => null;

  /// How much of the id the file name carries. Eight hex characters of a v4
  /// uuid is the same order of collision risk as the app's other short ids, and
  /// a full uuid in every name makes a directory listing unreadable.
  static const int idSuffixLength = 8;

  static const String _hashKey = 'capture-hash';

  String? get _root {
    final String? raw = _vaultPath();
    if (raw == null) return null;
    final String trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  bool get isConfigured => _root != null;

  @override
  Future<VaultWrite> mirror(VaultNote note) async {
    final String? root = _root;
    if (root == null) throw const VaultNotConfiguredException();

    final Directory vault = Directory(root);
    if (!await vault.exists()) {
      // Named rather than swallowed, on the same rule as a missing project
      // repository: an unmounted drive and an empty vault look identical from
      // the queue, and only one of them is the user's to fix.
      throw FileSystemException('Vault directory not found', root);
    }

    final Directory dir = Directory(p.join(root, _folderName()));
    await dir.create(recursive: true);

    final File? existing = await _locate(dir, note.id);
    final List<String> attachments = _copySources()
        ? _attachmentPathsFor(note)
        : const <String>[];
    final String body = _renderBody(note, attachments);
    final String hash = await _hash(body);

    if (existing != null) {
      final String current = await existing.readAsString();
      if (!await _isOurs(current)) {
        return VaultWrite(outcome: VaultOutcome.foreign, path: existing.path);
      }
      final String next = _render(note, hash, body);
      if (current == next) {
        return VaultWrite(
          outcome: VaultOutcome.unchanged,
          path: existing.path,
        );
      }
      await _copyAttachments(dir, attachments);
      await _write(existing, next);
      return VaultWrite(outcome: VaultOutcome.updated, path: existing.path);
    }

    final File file = File(p.join(dir.path, _fileNameFor(note)));
    await _copyAttachments(dir, attachments);
    await _write(file, _render(note, hash, body));
    return VaultWrite(outcome: VaultOutcome.created, path: file.path);
  }

  @override
  Future<int> countMirrored(Iterable<String> captureIds) async {
    final String? root = _root;
    if (root == null) return 0;

    final Directory vault = Directory(root);
    if (!await vault.exists()) return 0;

    final Directory dir = Directory(p.join(root, _folderName()));
    if (!await dir.exists()) return 0;

    final Set<String> targetShortIds = captureIds.map(_shortId).toSet();
    if (targetShortIds.isEmpty) return 0;

    int matched = 0;
    final Set<String> foundShortIds = <String>{};
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) continue;
      final String name = p.basename(entity.path);
      if (!name.endsWith('.md')) continue;
      final String withoutExt = name.substring(0, name.length - 3);
      final int dash = withoutExt.lastIndexOf('-');
      if (dash >= 0 && dash + 1 < withoutExt.length) {
        final String shortId = withoutExt.substring(dash + 1);
        if (targetShortIds.contains(shortId) && foundShortIds.add(shortId)) {
          matched++;
        }
      }
    }
    return matched;
  }

  String _folderName() {
    final String raw = _folder().trim();
    if (raw.isEmpty) return VaultDefaults.folder;
    // Two ways a folder name escapes the vault, and stripping only the first
    // left the second open. A leading separator makes `join` discard the vault
    // root and write to the filesystem root; a `..` segment walks out of it one
    // directory at a time, and `normalize` keeps those segments because from a
    // relative path's point of view they are meaningful. Neither is a name a
    // user meant to type, so both are dropped rather than reported.
    final List<String> segments = p
        .split(p.normalize(raw))
        .where(
          (String segment) =>
              segment.isNotEmpty &&
              segment != '.' &&
              segment != '..' &&
              segment != p.separator &&
              segment != '/' &&
              segment != r'\',
        )
        .toList();
    return segments.isEmpty ? VaultDefaults.folder : p.joinAll(segments);
  }

  /// Atomic, like every index this app writes, and here for a sharper reason
  /// than usual: a torn write leaves a file whose hash no longer matches its
  /// body, which this class would then read back as somebody else's edit and
  /// refuse to touch for good.
  Future<void> _write(File file, String content) async {
    final File temp = File('${file.path}.tmp');
    await temp.writeAsString(content, flush: true);
    await temp.rename(file.path);
  }

  /// The note for [id], whatever it has since been named.
  Future<File?> _locate(Directory dir, String id) async {
    final String suffix = '-${_shortId(id)}.md';
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) continue;
      if (p.basename(entity.path).endsWith(suffix)) return entity;
    }
    return null;
  }

  /// Whether the file on disk is still the one we wrote.
  Future<bool> _isOurs(String content) async {
    final _Parsed? parsed = _Parsed.of(content);
    if (parsed == null) return false;
    final String? claimed = parsed.frontMatter[_hashKey];
    if (claimed == null) return false;
    return claimed == await _hash(parsed.body);
  }

  static String _shortId(String id) => id.length <= idSuffixLength
      ? id
      : id.substring(0, idSuffixLength);

  static Future<String> _hash(String body) async {
    final Hash digest = await Sha256().hash(utf8.encode(body));
    return digest.bytes
        .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  // ---------------------------------------------------------------- rendering

  String _render(VaultNote note, String hash, String body) =>
      '${_renderFrontMatter(note, hash)}$body';

  String _renderFrontMatter(VaultNote note, String hash) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('---')
      ..writeln('title: ${_yaml(note.title)}')
      ..writeln('created: ${note.capturedAt.toIso8601String()}')
      ..writeln('type: ${note.type.name}');

    if (note.category != null) {
      buffer.writeln('category: ${note.category!.name}');
    }
    final String? project = _projectNameFor(note);
    if (project != null) buffer.writeln('project: ${_yaml(project)}');
    if (note.tags.isNotEmpty) {
      buffer.writeln('tags: [${note.tags.map(_yaml).join(', ')}]');
    }
    if (note.type.hasDuration && note.durationMs > 0) {
      buffer.writeln('duration: ${_formatDuration(note.durationMs)}');
    }
    // Segment 0 alone, as before: the key names the capture's own source, and
    // a list here would change the shape of every note already in a vault.
    final String? primary = note.sourcePaths.firstOrNull;
    if (primary != null) {
      buffer.writeln('source: ${_yaml(p.basename(primary))}');
    }

    buffer
      // Last two, and in this order, so the machinery sits at the bottom of the
      // property list the reader sees rather than above their own metadata.
      ..writeln('capture-id: ${note.id}')
      ..writeln('$_hashKey: $hash')
      // Ends on the fence itself: the blank line below belongs to the *body*,
      // because that is the text the hash is taken from and the text `_Parsed`
      // hands back. Move it up here and every note reads as foreign forever.
      ..writeln('---');
    return buffer.toString();
  }

  String? _projectNameFor(VaultNote note) {
    final String? id = note.projectId;
    if (id == null || id.isEmpty) return null;
    final String? name = _projectName(id)?.trim();
    return (name == null || name.isEmpty) ? null : name;
  }

  String _renderBody(VaultNote note, List<String> attachments) {
    final StringBuffer buffer = StringBuffer()
      ..writeln()
      ..writeln('# ${sanitizeUntrustedMarkdown(note.title)}')
      ..writeln();

    final String summary = sanitizeUntrustedMarkdown(note.summary ?? '');
    if (summary.isNotEmpty) {
      buffer
        ..writeln('> $summary')
        ..writeln();
    }
    for (final String attachment in attachments) {
      buffer
        ..writeln('![[${VaultDefaults.attachments}/${p.basename(attachment)}]]')
        ..writeln();
    }

    final String body = sanitizeUntrustedMarkdownBody(note.body).trim();
    if (body.isNotEmpty) {
      buffer
        ..writeln(body)
        ..writeln();
    }
    return buffer.toString();
  }

  /// Only types whose source is worth opening from the note. A text capture's
  /// `.txt` is the body already printed above it, so attaching it would put the
  /// same words in the vault twice.
  List<String> _attachmentPathsFor(VaultNote note) {
    if (note.type == CaptureType.text) return const <String>[];
    return note.sourcePaths;
  }

  Future<void> _copyAttachments(Directory dir, List<String> paths) async {
    for (final String path in paths) {
      await _copyAttachment(dir, path);
    }
  }

  Future<void> _copyAttachment(Directory dir, String path) async {
    final File source = File(path);
    if (!await source.exists()) return;

    final Directory target = Directory(
      p.join(dir.path, VaultDefaults.attachments),
    );
    await target.create(recursive: true);
    final File destination = File(p.join(target.path, p.basename(path)));

    // Sources are immutable once captured, so a copy that is already there with
    // the right length is the same file — worth checking, because re-copying a
    // 200 MB video on every title edit is not.
    if (await destination.exists() &&
        await destination.length() == await source.length()) {
      return;
    }
    await source.copy(destination.path);
  }

  /// `2026-08-05-1432-a-note-about-vaults-3f9a1c2e.md`
  String _fileNameFor(VaultNote note) {
    final DateTime at = note.capturedAt;
    final String stamp =
        '${at.year.toString().padLeft(4, '0')}-'
        '${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')}-'
        '${at.hour.toString().padLeft(2, '0')}'
        '${at.minute.toString().padLeft(2, '0')}';
    final String slug = _slug(note.title);
    final String middle = slug.isEmpty ? '' : '-$slug';
    return '$stamp$middle-${_shortId(note.id)}.md';
  }

  /// ASCII, lowercase, hyphenated — and Polish diacritics transliterated rather
  /// than dropped, because this app's captures are largely Polish and
  /// `notatka-o-wdroeniu` names nothing.
  static String _slug(String title) {
    final StringBuffer buffer = StringBuffer();
    for (final int rune in title.toLowerCase().runes) {
      final String char = String.fromCharCode(rune);
      buffer.write(_transliterate[char] ?? char);
    }
    final String ascii = buffer
        .toString()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp('^-+|-+\$'), '');
    return ascii.length <= _maxSlug ? ascii : _trimSlug(ascii);
  }

  static const int _maxSlug = 48;

  /// Cut on a word boundary when there is one nearby, so a truncated name reads
  /// as a shortened title rather than as a corrupted one.
  static String _trimSlug(String slug) {
    final String cut = slug.substring(0, _maxSlug);
    final int boundary = cut.lastIndexOf('-');
    return boundary > _maxSlug ~/ 2 ? cut.substring(0, boundary) : cut;
  }

  static const Map<String, String> _transliterate = <String, String>{
    'ą': 'a',
    'ć': 'c',
    'ę': 'e',
    'ł': 'l',
    'ń': 'n',
    'ó': 'o',
    'ś': 's',
    'ź': 'z',
    'ż': 'z',
  };

  /// Always quoted, never bare. A title is free text and can open with a `#`,
  /// hold a colon, or be the word `null` — each of which turns an unquoted
  /// scalar into a comment, a nested map, or a missing value in whatever reads
  /// the file next.
  static String _yaml(String value) {
    final String escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', ' ')
        .replaceAll('\r', ' ')
        .trim();
    return '"$escaped"';
  }

  static String _formatDuration(int milliseconds) {
    final Duration duration = Duration(milliseconds: milliseconds);
    final int minutes = duration.inMinutes.remainder(60);
    final int seconds = duration.inSeconds.remainder(60);
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${minutes.toString().padLeft(2, '0')}m';
    }
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }
}

/// A note split back into its two halves, so the hash can be checked against
/// exactly the text it was taken from.
class _Parsed {
  const _Parsed({required this.frontMatter, required this.body});

  final Map<String, String> frontMatter;
  final String body;

  /// Null when the file carries no front matter at all — a note the reader has
  /// rewritten from scratch, which is as foreign as an edited one.
  static _Parsed? of(String content) {
    if (!content.startsWith('---\n')) return null;
    final int end = content.indexOf('\n---\n', 3);
    if (end < 0) return null;

    final Map<String, String> fields = <String, String>{};
    for (final String line in content.substring(4, end + 1).split('\n')) {
      final int colon = line.indexOf(':');
      if (colon <= 0) continue;
      fields[line.substring(0, colon).trim()] = line
          .substring(colon + 1)
          .trim();
    }
    // `+5` clears the closing fence and its newline; the blank line the writer
    // puts after it belongs to the body, and must, or the hash would not match
    // what was hashed.
    return _Parsed(frontMatter: fields, body: content.substring(end + 5));
  }
}
