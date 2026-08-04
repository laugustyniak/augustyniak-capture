import 'dart:convert';
import 'dart:io';

/// What a project's repository says about itself, and where that came from.
class ProjectContextDocument {
  const ProjectContextDocument({required this.fileName, required this.text});

  /// Bare file name (`CLAUDE.md`), not the full path — it is shown in a log
  /// line and in the prompt, where the user's home directory has no business
  /// appearing.
  final String fileName;
  final String text;
}

/// Reads a project's own description straight out of its repository.
///
/// The whole point of the feature: the user should not have to restate what a
/// project is about inside this app, because they already wrote it down for
/// their coding agent. The repository stays the source of truth, so the
/// enrichment context updates itself when the file does.
///
/// Deliberately dependency-free — it takes a path and answers with text — so
/// it needs no `path_provider`, no platform channel, and its test can run
/// against a real temp directory instead of a fake.
class ProjectContextReader {
  const ProjectContextReader({this.candidates = defaultCandidates});

  /// Searched in order, first hit wins; they are **not** concatenated.
  ///
  /// The order is by intent, not by how common the file is. `CLAUDE.md` and
  /// `AGENTS.md` are written *to brief a model* and describe the work; a
  /// `README.md` is written for humans evaluating the repo and opens with
  /// badges and install steps. When both exist the agent brief is the better
  /// answer to "what is this project about".
  static const List<String> defaultCandidates = <String>[
    'CLAUDE.md',
    'AGENTS.md',
    'README.md',
    'readme.md',
  ];

  final List<String> candidates;

  /// Read no more than this off disk before truncating.
  ///
  /// `EnrichmentContext` clamps to a few thousand *characters* anyway, so this
  /// bound exists only to stop a pathological file — a README with an embedded
  /// base64 image, a generated changelog — from being pulled into memory in
  /// full on every capture.
  static const int maxBytes = 64 * 1024;

  /// Null when the repo path is blank, the directory is gone, or none of the
  /// [candidates] is there. All three are ordinary states — a project can be
  /// pointed at a repository that has no such file — so none of them throws.
  /// A file that exists but cannot be *read* does throw: that is a real fault
  /// and the caller logs it.
  Future<ProjectContextDocument?> read(String repoPath) async {
    final String root = repoPath.trim();
    if (root.isEmpty) return null;

    for (final String candidate in candidates) {
      final File file = File('$root${Platform.pathSeparator}$candidate');
      if (!await file.exists()) continue;
      final String text = await _readHead(file);
      if (text.trim().isEmpty) continue;
      return ProjectContextDocument(fileName: candidate, text: text);
    }
    return null;
  }

  /// One bounded read rather than `openRead`, and that is not only about
  /// allocations. A file *stream* schedules its own events, which never flow
  /// inside a `testWidgets` fake-async zone — a probe kicked from `initState`
  /// would hang the widget rather than fail it. A single `read` is one future
  /// the zone can complete.
  ///
  /// `allowMalformed` because the byte cut can land mid-codepoint — a Polish
  /// character split across the boundary must degrade to one replacement glyph,
  /// not throw away the whole context.
  static Future<String> _readHead(File file) async {
    final RandomAccessFile handle = await file.open();
    try {
      return utf8.decode(await handle.read(maxBytes), allowMalformed: true);
    } finally {
      await handle.close();
    }
  }
}
