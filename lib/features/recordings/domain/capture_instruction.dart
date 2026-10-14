import 'cleanup_proposal.dart';

/// The capture rewritten as an instruction (#281): misheard words repaired and
/// the dictation restated as a prompt for the task it describes.
///
/// **Beside the transcript, never over it.** The raw text stays in
/// `Recording.transcript`, which search, the vault and agent briefs keep
/// reading; this is what the clipboard receives and what the detail views open
/// on. Unlike a [CleanupProposal] there is nothing to accept: the instruction
/// is a derived view, and a stale one is simply written again.
class CaptureInstruction {
  const CaptureInstruction({required this.text, required this.source});

  final String text;

  /// [CleanupProposal.fingerprint] of the transcript this was written from.
  final String source;

  /// Whether this was written from [transcript] as it is now.
  bool matches(String? transcript) =>
      transcript != null && CleanupProposal.fingerprint(transcript) == source;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'text': text,
    'source': source,
  };

  /// Null for anything unreadable — degrade on load, never throw. Derived and
  /// re-creatable, so losing a malformed one costs one call.
  static CaptureInstruction? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? text = json['text'];
    final Object? source = json['source'];
    if (text is! String || source is! String || text.trim().isEmpty) {
      return null;
    }
    return CaptureInstruction(text: text, source: source);
  }
}
