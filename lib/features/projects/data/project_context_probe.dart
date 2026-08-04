import 'dart:io';

import '../domain/project.dart';
import 'project_context_reader.dart';

/// Where a project's enrichment context ends up coming from — or why it does
/// not exist.
///
/// The last three are the diagnosis the user actually needs. A mistyped
/// `repoPath` and a repository that genuinely has no `CLAUDE.md` produce the
/// same silence at enrichment time, and that ambiguity is exactly what makes a
/// feature like this feel broken rather than empty.
enum ProjectContextOutcome {
  /// A context file was found and will be sent.
  file,

  /// No file, but the project has a typed description to fall back on.
  description,

  /// Nothing to send.
  none,

  /// `repoPath` does not point at an existing directory.
  repoMissing,

  /// The directory is there but reading it threw — permissions, a broken
  /// symlink, an unmounted volume.
  unreadable,
}

/// What a project would contribute to the enrichment prompt right now.
class ProjectContextStatus {
  const ProjectContextStatus({
    required this.outcome,
    this.fileName,
    this.available = 0,
    this.sent = 0,
    this.error,
  });

  final ProjectContextOutcome outcome;

  /// `CLAUDE.md`, `AGENTS.md`, … — null unless [outcome] is
  /// [ProjectContextOutcome.file].
  final String? fileName;

  /// Characters found, and characters that survive the send-time ceiling. They
  /// differ exactly when the source is long enough to be truncated, which is
  /// the one fact a user cannot discover any other way.
  final int available;
  final int sent;

  final String? error;

  bool get isTruncated => available > sent;

  /// One line for the Config tab. Formatting lives here rather than in the
  /// widget so it can be asserted without pumping a frame.
  String get summary => switch (outcome) {
    ProjectContextOutcome.file =>
      isTruncated
          ? '$fileName · $sent of $available chars sent'
          : '$fileName · $available chars',
    ProjectContextOutcome.description => 'project description · $sent chars',
    ProjectContextOutcome.none => 'no context file, no description',
    ProjectContextOutcome.repoMissing => 'repository path not found',
    ProjectContextOutcome.unreadable => 'unreadable: ${error ?? 'unknown'}',
  };

  /// True for the states worth colouring amber: the context is missing for a
  /// reason the user can fix.
  bool get needsAttention =>
      outcome == ProjectContextOutcome.repoMissing ||
      outcome == ProjectContextOutcome.unreadable ||
      outcome == ProjectContextOutcome.none;
}

/// Answers "what would this project actually send?" without enriching anything.
///
/// Separate from [ProjectContextReader] because it asks a different question:
/// the reader returns text for the prompt, this reports on the *lookup* — which
/// is why it distinguishes a missing repository from a repository with no
/// context file, something the reader deliberately collapses to null.
class ProjectContextProbe {
  const ProjectContextProbe({
    this.reader = const ProjectContextReader(),
    required this.sendLimit,
  });

  final ProjectContextReader reader;

  /// The send-time ceiling, passed in rather than imported so this layer stays
  /// independent of the enrichment feature.
  final int sendLimit;

  Future<ProjectContextStatus> probe(Project project) async {
    final String root = project.repoPath.trim();
    final String? description = project.description?.trim();

    ProjectContextStatus fallback(ProjectContextOutcome whenNoDescription) {
      if (description == null || description.isEmpty) {
        return ProjectContextStatus(outcome: whenNoDescription);
      }
      return ProjectContextStatus(
        outcome: ProjectContextOutcome.description,
        available: description.length,
        sent: _clamp(description.length),
      );
    }

    // A blank path is not an error the user needs flagged — it just means the
    // project was never pointed at a checkout, and the description still works.
    if (root.isEmpty) return fallback(ProjectContextOutcome.none);
    if (!await Directory(root).exists()) {
      // Reported even when a description exists: the path is wrong either way,
      // and staying quiet about it is how a typo survives for months.
      return const ProjectContextStatus(
        outcome: ProjectContextOutcome.repoMissing,
      );
    }

    try {
      final ProjectContextDocument? document = await reader.read(root);
      if (document == null) return fallback(ProjectContextOutcome.none);
      return ProjectContextStatus(
        outcome: ProjectContextOutcome.file,
        fileName: document.fileName,
        available: document.text.length,
        sent: _clamp(document.text.length),
      );
    } catch (exception) {
      return ProjectContextStatus(
        outcome: ProjectContextOutcome.unreadable,
        error: exception.toString(),
      );
    }
  }

  int _clamp(int length) => length > sendLimit ? sendLimit : length;
}
