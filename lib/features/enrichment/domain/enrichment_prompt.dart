import '../../recordings/domain/capture_category.dart';

/// Head and tail kept when the text is longer than their sum. A 90-minute
/// transcript would otherwise cost more to enrich than it cost to transcribe.
const int _headChars = 8000;
const int _tailChars = 4000;

/// The system prompt, **generated from [CaptureCategory]** rather than written
/// out by hand.
///
/// A hand-written list desyncs from the enum the first time a category is added,
/// and the failure is silent: the model simply never emits the new label. The
/// `switch` in [_describe] is exhaustive, so adding a value to the enum breaks
/// the build here until its description is written.
String buildEnrichmentSystemPrompt() {
  final StringBuffer buffer = StringBuffer()
    ..writeln(
      'You classify captured notes, transcripts and OCR text for a personal '
      'capture inbox. Reply with a single JSON object and nothing else.',
    )
    ..writeln()
    ..writeln('Fields:')
    ..writeln('- "title": max 60 characters, no trailing period.')
    ..writeln('- "category": exactly one of the values listed below.')
    ..writeln('- "summary": one sentence, max 200 characters.')
    ..writeln('- "tags": 3 to 5 short lowercase tags, no "#".')
    ..writeln()
    ..writeln(
      'Write "title" and "summary" in the same language as the input text.',
    )
    ..writeln()
    ..writeln('Categories (each is a routing destination, not a topic):');

  for (final CaptureCategory category in CaptureCategory.values) {
    buffer.writeln('- "${category.name}": ${_describe(category)}');
  }

  buffer
    ..writeln()
    ..writeln(
      'If none of them clearly fits, use "capture". Do not invent a category.',
    );
  return buffer.toString();
}

String _describe(CaptureCategory category) => switch (category) {
      CaptureCategory.note =>
        'durable knowledge or reference material worth keeping',
      CaptureCategory.task => 'something a person has to do',
      CaptureCategory.agentTask =>
        'an instruction or spec meant for an AI agent to execute',
      CaptureCategory.idea =>
        'a product or business idea that is not yet actionable',
      CaptureCategory.meetingNote =>
        'notes from a meeting or call, with people and decisions',
      CaptureCategory.researchLead =>
        'a paper, link, tool or topic to look into later',
      CaptureCategory.capture => 'anything that fits none of the above',
    };

/// Head + tail, so the closing words of a recording survive — they usually
/// carry the conclusion, and a head-only cut would drop it.
String truncateForEnrichment(String text) {
  if (text.length <= _headChars + _tailChars) return text;
  final String head = text.substring(0, _headChars);
  final String tail = text.substring(text.length - _tailChars);
  return '$head\n[...]\n$tail';
}
