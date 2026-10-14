import 'capture_router.dart';

/// The default opening prompt for a capture: **its own text**, and nothing
/// wrapped around it.
///
/// The body is the whole prompt whenever there is one: a dictated note already
/// says what it wants done, and a generated preamble would only compete with
/// it. The title is the last fallback rather than a header, because an
/// un-enriched capture's title is `displayNameFor`'s stand-in — `Recording
/// 14:32` — which is noise at the top of a prompt and the only thing left at
/// the bottom of an empty one. The category and tags stay out entirely: they
/// are how the *queue* files a capture, not what the task is.
///
/// A pure function in the domain so a capture with no project — which has no
/// `AgentHandoff` to ask — still has a prompt. Empty means there is nothing to
/// send.
String capturePrompt(RoutedCapture capture) {
  final String body = capture.body.trim();
  if (body.isNotEmpty) return body;
  final String summary = capture.summary?.trim() ?? '';
  if (summary.isNotEmpty) return summary;
  return capture.title.trim();
}
