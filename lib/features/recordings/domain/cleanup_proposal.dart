import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A cleaned-up version of a capture's transcript, waiting for the user to
/// accept or reject it (#258).
///
/// **A proposal, never an overwrite.** The model's output lives here, beside
/// `Recording.transcript`, and reaches the transcript only through an explicit
/// accept — which goes through the normal edit path, so the revision history
/// keeps the raw text.
class CleanupProposal {
  const CleanupProposal({required this.text, required this.source});

  /// The cleaned text.
  final String text;

  /// [fingerprint] of the transcript the proposal was made from. When the
  /// transcript changes afterwards — a hand edit, an appended segment — the
  /// proposal describes text that no longer exists, and is stale.
  final String source;

  /// Eight hex characters of the sha-256 of [text], exactly as stored: it only
  /// has to tell versions of one capture's transcript apart.
  static String fingerprint(String text) =>
      sha256.convert(utf8.encode(text)).toString().substring(0, 8);

  /// Whether this proposal was made from [transcript] as it is now.
  bool matches(String? transcript) =>
      transcript != null && fingerprint(transcript) == source;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'text': text,
    'source': source,
  };

  /// Null for anything unreadable — degrade on load, never throw. A proposal
  /// is derived and re-creatable, so losing a malformed one costs one call.
  static CleanupProposal? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? text = json['text'];
    final Object? source = json['source'];
    if (text is! String || source is! String || text.trim().isEmpty) {
      return null;
    }
    return CleanupProposal(text: text, source: source);
  }
}
