import 'dart:io';

import '../../projects/domain/project.dart';
import '../domain/capture_router.dart';
import '../domain/route_record.dart';
import '../domain/untrusted_markdown.dart';

/// Appends a capture to `inbox.md` in its project's repository.
///
/// A file was chosen as the first real destination deliberately, over any of
/// the trackers the categories imply. It needs no API, no token and no network,
/// so it does not trade away the one property the whole app is built on; the
/// repository is already the source of truth for a project's context, so the
/// same directory is where its inbox belongs; and the result is readable and
/// editable by every tool the user already has, including the coding agent that
/// will read the repo next.
///
/// **Append-only, like `revisions.jsonl` and for the same reason.** Everything
/// else in this app rewrites its file wholesale, which is exactly the shape
/// that once let one bad read destroy the index. A destination file is not even
/// ours — the user edits it — so it must never be rewritten from memory:
/// `FileMode.writeOnlyAppend` can lose at most the entry being written, and
/// cannot lose a word the user put there.
class ProjectInboxRouter implements CaptureRouter {
  const ProjectInboxRouter({
    required Project? Function(String projectId) projectById,
    this.fileName = 'inbox.md',
  }) : _projectById = projectById;

  final Project? Function(String projectId) _projectById;
  final String fileName;

  Project? _resolve(String? projectId) {
    if (projectId == null || projectId.isEmpty) return null;
    // A project deleted after the capture was filed leaves a dangling id on the
    // item, the same shape as a dangling `activeProfileId`.
    final Project? project = _projectById(projectId);
    if (project == null) return null;
    return project.repoPath.trim().isEmpty ? null : project;
  }

  @override
  bool canRoute(String? projectId) => _resolve(projectId) != null;

  @override
  Future<RouteRecord> route(RoutedCapture capture) async {
    final Project? project = _resolve(capture.projectId);
    if (project == null) throw const CaptureRoutingUnavailableException();

    final Directory repo = Directory(project.repoPath);
    if (!await repo.exists()) {
      // Named rather than swallowed: a moved checkout and an empty inbox look
      // identical from the queue, and only one of them is the user's problem.
      throw FileSystemException('Project repository not found', project.repoPath);
    }

    final File file = File('${project.repoPath}${Platform.pathSeparator}$fileName');
    await file.writeAsString(_render(capture), mode: FileMode.writeOnlyAppend);
    return RouteRecord(
      // Stamped here rather than by the caller so the record cannot claim a
      // delivery time earlier than the write that produced it.
      at: DateTime.now(),
      kind: RouteKind.file,
      target: '$fileName · ${project.name}',
    );
  }

  String _render(RoutedCapture capture) {
    final StringBuffer buffer = StringBuffer()
      ..writeln()
      ..writeln('## ${sanitizeUntrustedMarkdown(capture.title)}')
      ..writeln();

    final List<String> facts = <String>[
      capture.capturedAt.toIso8601String(),
      if (capture.category != null) capture.category!.name,
      ...capture.tags.map((String tag) => '#$tag'),
    ];
    buffer
      ..writeln('*${facts.join(' · ')}*')
      ..writeln();

    final String summary = sanitizeUntrustedMarkdown(capture.summary ?? '');
    if (summary.isNotEmpty) {
      buffer
        ..writeln('> $summary')
        ..writeln();
    }

    final String body = sanitizeUntrustedMarkdownBody(capture.body).trim();
    if (body.isNotEmpty) {
      buffer
        ..writeln(body)
        ..writeln();
    }
    return buffer.toString();
  }
}
