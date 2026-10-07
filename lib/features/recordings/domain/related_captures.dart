import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'recording.dart';

/// One capture's vector, as stored (#272).
///
/// Derived data: re-creatable from the transcript, never synced, never in
/// `recordings.json`. Losing every one of them costs a rebuild, not a capture.
class StoredEmbedding {
  StoredEmbedding({
    required this.captureId,
    required this.fingerprint,
    required this.model,
    required this.vector,
  });

  final String captureId;

  /// [embeddingFingerprint] of the text the vector was made from. A capture
  /// whose text has changed since no longer matches, and its vector is not
  /// used — an edited transcript is never found by what it used to say.
  final String fingerprint;

  /// The embedding model. Vectors from two models are never compared.
  final String model;
  final Float32List vector;
}

/// Another capture close in meaning to the one being looked at.
class RelatedCapture {
  const RelatedCapture({
    required this.id,
    required this.score,
    required this.duplicate,
  });

  final String id;

  /// Cosine similarity, -1 to 1.
  final double score;

  /// Close enough to be the same thought said twice.
  final bool duplicate;
}

/// Thresholds tuned for OpenAI's `text-embedding-3-*`, where unrelated text
/// scores around 0.1–0.3. Other models spread their scores differently, which
/// is a reason to keep these in one place, not a reason to expose them yet.
abstract final class RelatedLimits {
  const RelatedLimits._();

  static const double related = .5;
  static const double repeat = .7;
  static const double duplicate = .9;
  static const int topN = 5;

  /// How far around a capture a near-repeat still counts as "said again".
  static const Duration repeatWindow = Duration(days: 14);

  /// The card shows the repeat badge from this many sayings, the capture
  /// itself included.
  static const int repeatBadgeAt = 3;

  /// The head of a transcript that is embedded. Embedding models cap their
  /// input (8191 tokens for OpenAI); the head carries what a capture is about.
  static const int maxChars = 8000;
}

/// The text a capture is embedded from: its transcript, head-truncated. Null
/// when there is nothing to embed.
String? embeddingInput(Recording recording) {
  final String text = (recording.transcript ?? '').trim();
  if (text.isEmpty) return null;
  return text.length <= RelatedLimits.maxChars
      ? text
      : text.substring(0, RelatedLimits.maxChars);
}

/// Sixteen hex characters of the sha-256 of [text].
String embeddingFingerprint(String text) =>
    sha256.convert(utf8.encode(text)).toString().substring(0, 16);

/// Cosine similarity of [a] and [b]; 0 when the dimensions differ or either
/// is all zeros, so a malformed vector can never look related.
double cosine(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0;
  double dot = 0;
  double na = 0;
  double nb = 0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// The captures in [vectors] closest to [id], best first: at most
/// [RelatedLimits.topN], each at or above [RelatedLimits.related], never [id]
/// itself. Empty when [id] has no vector.
List<RelatedCapture> rankRelated(String id, Map<String, List<double>> vectors) {
  final List<double>? self = vectors[id];
  if (self == null) return const <RelatedCapture>[];
  final List<RelatedCapture> found = <RelatedCapture>[
    for (final MapEntry<String, List<double>> other in vectors.entries)
      if (other.key != id)
        if (cosine(self, other.value) case final double score
            when score >= RelatedLimits.related)
          RelatedCapture(
            id: other.key,
            score: score,
            duplicate: score >= RelatedLimits.duplicate,
          ),
  ]..sort((RelatedCapture a, RelatedCapture b) => b.score.compareTo(a.score));
  return found.take(RelatedLimits.topN).toList();
}

/// Where vectors live. Synchronous, like `UsageRepository`: sqlite3 is a
/// synchronous binding, and a vector is a few kilobytes.
///
/// [InMemoryEmbeddingStore] is the default, so the pure-Dart suite and any
/// host without the database still find related captures for the session;
/// the shell installs the SQLite one.
abstract interface class EmbeddingStore {
  /// Every stored vector made by [model], by capture id.
  Map<String, StoredEmbedding> load(String model);
  void put(StoredEmbedding embedding);

  /// Drops every vector of [captureId], whichever model made it.
  void remove(String captureId);
}

class InMemoryEmbeddingStore implements EmbeddingStore {
  final Map<String, StoredEmbedding> _byKey = <String, StoredEmbedding>{};

  @override
  Map<String, StoredEmbedding> load(String model) => <String, StoredEmbedding>{
    for (final StoredEmbedding each in _byKey.values)
      if (each.model == model) each.captureId: each,
  };

  @override
  void put(StoredEmbedding embedding) =>
      _byKey['${embedding.model}\u0000${embedding.captureId}'] = embedding;

  @override
  void remove(String captureId) => _byKey.removeWhere(
    (String _, StoredEmbedding e) => e.captureId == captureId,
  );
}

/// Where a running index build is. [done] counts every item finished with,
/// whatever the outcome.
class IndexProgress {
  const IndexProgress({required this.done, required this.total});

  final int done;
  final int total;

  IndexProgress advance() => IndexProgress(done: done + 1, total: total);
}
