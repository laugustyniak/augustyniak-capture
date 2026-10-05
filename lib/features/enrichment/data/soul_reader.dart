import 'dart:convert';
import 'dart:io';

import '../domain/enrichment_context.dart';

/// Where the profile ("soul") sent with a capture actually came from.
///
/// Five states, not two, for the same reason `ProjectContextProbe` has its
/// own: at enrichment time a mistyped path, an empty file and a file the app
/// may not read are all silence. Only [file] means the file was used; the
/// three failure states fall back to the typed profile and say so.
enum SoulOrigin {
  /// No soul file is configured: the typed profile is the soul.
  typed,

  /// The file was read and its text was used.
  file,

  /// A path is configured, but nothing is there.
  missing,

  /// The file exists and holds nothing but whitespace.
  empty,

  /// The file exists and could not be read — a directory, a permission.
  unreadable;

  /// Whether a configured file failed and the typed profile stood in for it.
  bool get isFallback => this == missing || this == empty || this == unreadable;
}

/// The profile text to send, and the facts the Config tab and the log report.
class ResolvedSoul {
  const ResolvedSoul({
    required this.origin,
    required this.text,
    this.fileName,
    this.error,
  });

  final SoulOrigin origin;

  /// What goes into `EnrichmentContext.profile`. Never null: a failing file
  /// falls back to the typed profile, which may itself be blank.
  final String text;

  /// Bare file name, for the log and the prompt — never the full path, which
  /// carries the user's home directory.
  final String? fileName;

  /// Why [SoulOrigin.unreadable], for the log line.
  final String? error;

  /// Whether the text that was read runs past what is sent.
  bool get truncated =>
      origin == SoulOrigin.file &&
      text.trim().length > EnrichmentContext.maxProfileChars;
}

/// Reads the user's soul from a markdown file they own, falling back to the
/// profile typed in the Config tab.
///
/// The file is read **per call** rather than cached, so editing it in another
/// app reaches the very next capture — the same reason `ProjectContextReader`
/// re-reads a repository's `CLAUDE.md` every time.
///
/// Never throws. A soul that cannot be read must cost a worse rank, never the
/// enrichment, and never the capture.
class SoulReader {
  const SoulReader();

  /// The name the browse button appends to a chosen folder.
  static const String defaultFileName = 'SOUL.md';

  /// Bounded for the same reason as `ProjectContextReader.maxBytes`: the
  /// profile is clamped to a few thousand characters anyway, and a
  /// pathological file must not be pulled into memory on every capture.
  static const int maxBytes = 64 * 1024;

  Future<ResolvedSoul> resolve({
    required String? path,
    required String typed,
  }) async {
    final String trimmed = path?.trim() ?? '';
    if (trimmed.isEmpty) {
      return ResolvedSoul(origin: SoulOrigin.typed, text: typed);
    }
    final File file = File(trimmed);
    final String fileName = file.uri.pathSegments.isEmpty
        ? trimmed
        : file.uri.pathSegments.last;
    try {
      // A directory answers `false` here, and so does a dangling path: both
      // are "nothing to read at that name".
      if (!await file.exists()) {
        final bool isDirectory = await Directory(trimmed).exists();
        return ResolvedSoul(
          origin: isDirectory ? SoulOrigin.unreadable : SoulOrigin.missing,
          text: typed,
          fileName: fileName,
          error: isDirectory ? 'is a directory, not a file' : null,
        );
      }
      final String text = await _readHead(file);
      if (text.trim().isEmpty) {
        return ResolvedSoul(
          origin: SoulOrigin.empty,
          text: typed,
          fileName: fileName,
        );
      }
      return ResolvedSoul(
        origin: SoulOrigin.file,
        text: text,
        fileName: fileName,
      );
    } catch (exception) {
      return ResolvedSoul(
        origin: SoulOrigin.unreadable,
        text: typed,
        fileName: fileName,
        error: '$exception',
      );
    }
  }

  /// One bounded `read`, not a stream — see `ProjectContextReader._readHead`
  /// for why a stream hangs inside a widget test's fake-async zone.
  static Future<String> _readHead(File file) async {
    final RandomAccessFile handle = await file.open();
    try {
      return utf8.decode(await handle.read(maxBytes), allowMalformed: true);
    } finally {
      await handle.close();
    }
  }
}
