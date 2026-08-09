import '../domain/closure_event.dart';

/// A [ClosureLog] that also hands each appended event to a listener.
///
/// A decorator rather than a second callback on `RecordingsController`, the
/// same shape `ChunkedTranscriptionService` uses over `TranscriptionService`.
/// The controller keeps one seam for closures and does not learn that anything
/// on screen wants to hear about them; the shell composes the two.
///
/// It exists so the count moves in the frame the capture leaves the queue.
/// Without it `MomentumController` would hold whatever it read at start-up and
/// only catch up on the next launch — the panel would be quietly stale for the
/// whole session, which is the least trustworthy state a counter can be in.
///
/// **[onAppended] runs only after the inner append succeeds.** Reporting a
/// closure the store rejected would put a number on screen that the next launch
/// silently takes back.
class NotifyingClosureLog implements ClosureLog {
  const NotifyingClosureLog(this._inner, this.onAppended);

  final ClosureLog _inner;

  /// Called with each successfully appended event. A callback rather than a
  /// direct reference so the shell can wire a controller that is constructed
  /// after this one.
  final void Function(ClosureEvent event) onAppended;

  @override
  Future<List<ClosureEvent>> load() => _inner.load();

  @override
  Future<void> append(ClosureEvent event) async {
    await _inner.append(event);
    onAppended(event);
  }
}
