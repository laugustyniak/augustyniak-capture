/// The one serializer for `.agent-tasks/<capture-id>.md`.
///
/// The file already existed and already carried the title, the summary, the
/// tags and the transcript — that is why a twenty-minute dictation travels to
/// an agent intact where a command-line argument would have been truncated.
/// What it lacked was anything a *machine* could read: a reader had to infer
/// the capture's identity from the file name and its category from a line of
/// italics. This adds YAML front matter on top and changes nothing below it.
///
/// **One serializer, deliberately, before there are two writers.** The plan it
/// comes from (`docs/plans/2026-08-06-command-intake-integration.md`) puts a
/// second producer of this exact format behind an HTTP control plane in a later
/// slice. Writing the format for the launcher that exists today means the two
/// cannot drift, and means the format is exercised by real use before anything
/// depends on it — `augustyniak-command plan --brief <path>` reads it already,
/// so a brief is pipeable over `ssh` the moment this lands.
///
/// It lives in `recordings/domain/` rather than in `projects/domain/`, where
/// the plan named it. `RoutedCapture` is here, and `agent_handoff.dart` states
/// the reason in full: `ProjectInboxRouter` already makes `recordings` depend
/// on `projects`, so a file in `projects` reaching back for `RoutedCapture`
/// would close the cycle that layer is written to avoid. Nothing else about the
/// slice changes.
library;

import 'capture_router.dart';
import 'untrusted_markdown.dart';
/// Renders one brief, or one section of one.
///
/// [includeHeader] is false for every handoff after the first, which is what
/// makes the file append-only in practice as well as in mode: the front matter
/// and the heading are written once, and a second handoff adds only its own
/// `## Handoff` section beneath whatever the agent has since written there.
/// Re-emitting the header would put a second front-matter block in the middle
/// of the file, where every YAML reader would ignore it and every human would
/// read it as the start of a different document.
String renderCaptureBrief({
  required String captureId,
  required RoutedCapture capture,
  required DateTime at,
  required bool includeHeader,
  required String resultPath,
  String? intent,
}) {
  final StringBuffer buffer = StringBuffer();
  if (includeHeader) {
    _writeFrontMatter(buffer, captureId: captureId, capture: capture, intent: intent);
    buffer
      ..writeln()
      ..writeln('# ${sanitizeUntrustedMarkdown(capture.title)}')
      ..writeln()
      ..writeln(
        '> **Output Contract**: Save your primary summary, deep research, or '
        'final results to `$resultPath`, or include `capture-id: $captureId` '
        'in created markdown notes.',
      )
      ..writeln();
  }

  buffer
    ..writeln('## Handoff ${at.toIso8601String()}')
    ..writeln();

  final String summary = sanitizeUntrustedMarkdown(capture.summary ?? '');
  if (summary.isNotEmpty) {
    buffer
      ..writeln('> $summary')
      ..writeln();
  }

  // The transcript, and the one place a `---` line is expected to appear. It
  // cannot be mistaken for a front-matter delimiter: the block above is opened
  // and closed before this is written, and only a fence on the very first line
  // of a file opens one. That is a property of where the text is placed, not of
  // anything escaped into it — so the transcript reaches the agent verbatim.
  final String body = sanitizeUntrustedMarkdownBody(capture.body).trim();
  if (body.isNotEmpty) {
    buffer
      ..writeln(body)
      ..writeln();
  }
  return buffer.toString();
}

/// The machine-readable half.
///
/// A key whose value would be empty is omitted rather than written blank. YAML
/// makes `category:` with nothing after it the value `null`, which is a claim —
/// "this capture was classified, as nothing" — and the queue draws exactly that
/// distinction: a null category means enrichment never ran, while `capture`
/// means the model looked and could not place it. An absent key says the honest
/// thing, which is that there is no answer to report.
void _writeFrontMatter(
  StringBuffer buffer, {
  required String captureId,
  required RoutedCapture capture,
  String? intent,
}) {
  buffer
    ..writeln('---')
    ..writeln('capture-id: $captureId')
    ..writeln('created: ${capture.capturedAt.toIso8601String()}')
    ..writeln('source: ${capture.type.name}');

  if (capture.category != null) {
    buffer.writeln('category: ${capture.category!.name}');
  }
  if (capture.tags.isNotEmpty) {
    buffer.writeln('tags: [${capture.tags.map(_yaml).join(', ')}]');
  }
  final String trimmedIntent = intent?.trim() ?? '';
  if (trimmedIntent.isNotEmpty) {
    buffer.writeln('intent: ${_yaml(trimmedIntent)}');
  }
  buffer.writeln('---');
}

/// Always quoted, never bare, on the same rule as the note vault's front
/// matter: a tag can be the word `null`, can open with a `#`, and can hold a
/// colon — each of which turns an unquoted scalar into a missing value, a
/// comment, or a nested map in whatever reads the file next.
String _yaml(String value) {
  final String escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', ' ')
      .replaceAll('\r', ' ')
      .trim();
  return '"$escaped"';
}
