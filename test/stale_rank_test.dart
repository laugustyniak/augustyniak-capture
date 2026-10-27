import 'package:augustyniak_capture/features/recordings/domain/capture_priority.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/stale_rank.dart';
import 'package:flutter_test/flutter_test.dart';

Recording _item(
  String id, {
  CapturePriority? priority,
  String? basis,
  bool done = false,
}) => Recording(
  id: id,
  filePath: '/tmp/$id.txt',
  createdAt: DateTime.utc(2026, 10, 6),
  durationMs: 0,
  status: RecordingStatus.completed,
  priority: priority,
  priorityBasis: basis,
  isProcessedByUser: done,
);

void main() {
  const String current = 'cafe0001';

  test('a model rank under an older soul is stale', () {
    expect(
      isStaleRank(
        _item('a', priority: CapturePriority.p1, basis: 'old00000'),
        current,
      ),
      isTrue,
    );
  });

  test('a rank under the current soul is not stale', () {
    expect(
      isStaleRank(
        _item('a', priority: CapturePriority.p1, basis: current),
        current,
      ),
      isFalse,
    );
  });

  test('a hand-set or legacy rank (no basis) is never stale', () {
    expect(
      isStaleRank(_item('a', priority: CapturePriority.p1), current),
      isFalse,
    );
  });

  test('an unranked item is never stale, even with a stray basis', () {
    expect(isStaleRank(_item('a', basis: 'old00000'), current), isFalse);
  });

  test('with no profile to rank against, nothing is stale', () {
    expect(
      isStaleRank(
        _item('a', priority: CapturePriority.p1, basis: 'old00000'),
        null,
      ),
      isFalse,
    );
  });

  test('handed-off captures are left out of the re-rank set', () {
    final List<Recording> set = staleRanks(<Recording>[
      _item('desk', priority: CapturePriority.p2, basis: 'old00000'),
      _item('off', priority: CapturePriority.p2, basis: 'old00000', done: true),
      _item('hand', priority: CapturePriority.p0),
    ], current);

    expect(set.map((Recording r) => r.id), <String>['desk']);
  });
}
