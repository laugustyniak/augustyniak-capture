import 'package:augustyniak_capture/features/recordings/domain/capture_priority.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_list_row.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_priority.dart';
import 'package:flutter_test/flutter_test.dart';

/// Newest first, the controller's order: `minute` counts down the list.
Recording _item(String id, CapturePriority? priority, {required int minute}) =>
    Recording(
      id: id,
      filePath: '/tmp/$id.m4a',
      createdAt: DateTime(2026, 10, 3, 12, minute),
      durationMs: 1000,
      status: RecordingStatus.completed,
      priority: priority,
    );

void main() {
  // Controller order: newest first.
  final List<Recording> queue = <Recording>[
    _item('a', CapturePriority.p2, minute: 50),
    _item('b', null, minute: 40),
    _item('c', CapturePriority.p0, minute: 30),
    _item('d', CapturePriority.p2, minute: 20),
    _item('e', CapturePriority.p3, minute: 10),
    _item('f', CapturePriority.p0, minute: 5),
  ];

  List<String> ids(Iterable<Recording> items) =>
      items.map((Recording item) => item.id).toList();

  group('PriorityFilter', () {
    test('each rank matches only its own items', () {
      expect(
        ids(queue.where((r) => matchesPriority(PriorityFilter.p0, r))),
        <String>['c', 'f'],
      );
      expect(
        ids(queue.where((r) => matchesPriority(PriorityFilter.p3, r))),
        <String>['e'],
      );
    });

    test('unranked is its own bucket, never folded into p3', () {
      expect(
        ids(queue.where((r) => matchesPriority(PriorityFilter.unranked, r))),
        <String>['b'],
      );
    });

    test('the specific buckets partition the queue and all is their union', () {
      int count(PriorityFilter filter) =>
          queue.where((r) => matchesPriority(filter, r)).length;

      final int parts = PriorityFilter.values
          .where((PriorityFilter f) => f != PriorityFilter.all)
          .map(count)
          .fold(0, (int sum, int n) => sum + n);
      expect(parts, queue.length);
      expect(count(PriorityFilter.all), queue.length);
    });
  });

  group('sortForQueue', () {
    test('newest keeps the controller order untouched', () {
      expect(ids(sortForQueue(queue, QueueSort.newest)), ids(queue));
    });

    test(
      'priority orders p0 to p3, unranked last, newest first within a rank',
      () {
        expect(ids(sortForQueue(queue, QueueSort.priority)), <String>[
          'c',
          'f',
          'a',
          'd',
          'e',
          'b',
        ]);
      },
    );

    test('does not mutate the list it was given', () {
      final List<Recording> copy = List<Recording>.of(queue);
      sortForQueue(copy, QueueSort.priority);
      expect(ids(copy), ids(queue));
    });
  });

  group('groupForQueue', () {
    test('newest groups by day, as before', () {
      final List<QueueDayGroup> groups = groupForQueue(
        queue,
        QueueSort.newest,
        DateTime(2026, 10, 3, 13),
      );
      expect(groups.map((QueueDayGroup g) => g.label), <String>['Today']);
    });

    test('priority groups by rank, in sorted order', () {
      final List<QueueDayGroup> groups = groupForQueue(
        sortForQueue(queue, QueueSort.priority),
        QueueSort.priority,
        DateTime(2026, 10, 3, 13),
      );
      expect(groups.map((QueueDayGroup g) => g.label), <String>[
        'P0',
        'P2',
        'P3',
        'Unranked',
      ]);
      expect(ids(groups.first.items), <String>['c', 'f']);
    });
  });
}
