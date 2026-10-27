import 'recording.dart';

/// Whether [item]'s priority was judged by the model against a soul that is no
/// longer the current one.
///
/// Only a model-assigned rank can be stale: it carries the fingerprint of the
/// profile it was judged against (`Recording.priorityBasis`). Never stale:
///
/// - a **hand-set** rank — no basis, because it was judged against nothing;
/// - a rank from before fingerprints existed — also no basis, and therefore
///   indistinguishable from a hand-set one, so it is left alone rather than
///   guessed at;
/// - an **unranked** item — ranking that is ordinary enrichment.
///
/// A null [currentBasis] means no profile would be sent now, which leaves
/// nothing to re-rank against, so nothing is stale.
bool isStaleRank(Recording item, String? currentBasis) =>
    currentBasis != null &&
    item.priority != null &&
    item.priorityBasis != null &&
    item.priorityBasis != currentBasis;

/// The captures a re-rank would touch: stale, and still on the desk. A capture
/// already handed off no longer needs a rank, and paying a model call for it
/// would buy nothing.
List<Recording> staleRanks(Iterable<Recording> items, String? currentBasis) =>
    <Recording>[
      for (final Recording item in items)
        if (!item.isProcessedByUser && isStaleRank(item, currentBasis)) item,
    ];

/// Where a running re-rank is. [done] counts every item the pass has finished
/// with, whatever the outcome, so the bar reaches [total] even on failures.
class RerankProgress {
  const RerankProgress({required this.done, required this.total});

  final int done;
  final int total;

  RerankProgress advance() => RerankProgress(done: done + 1, total: total);
}

/// What a finished (or cancelled) re-rank did, for the log and the Config tab.
class RerankSummary {
  const RerankSummary({
    this.reranked = 0,
    this.skipped = 0,
    this.failed = 0,
    this.cancelled = false,
  });

  /// A new rank was written.
  final int reranked;

  /// No longer stale when its turn came — a hand-set rank, a deletion, no
  /// text — or the model gave no usable rank.
  final int skipped;
  final int failed;
  final bool cancelled;
}
