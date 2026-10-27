import '../domain/capture_priority.dart';
import '../domain/recording.dart';
import 'queue_list_row.dart';

/// The priority axis of the queue's filters.
///
/// [unranked] is a bucket of its own rather than part of [p3]: "never ranked"
/// and "ranked low" are different facts (see `CapturePriority`), and folding
/// them would hide every capture enrichment never reached under the label for
/// things judged unimportant. The specific buckets partition the queue, and
/// [all] is their union — the same arithmetic as `RecordingFilter`.
enum PriorityFilter {
  all,
  p0,
  p1,
  p2,
  p3,
  unranked;

  String get label => switch (this) {
    PriorityFilter.all => 'PRIORITY',
    PriorityFilter.unranked => 'UNRANKED',
    _ => name.toUpperCase(),
  };
}

/// The list order. [newest] is the controller's order and the default, so a
/// user who never touches the toggle sees nothing move.
enum QueueSort { newest, priority }

/// Single definition of the priority axis, used for both the list and the
/// menu's counts so the two cannot disagree.
bool matchesPriority(PriorityFilter filter, Recording item) => switch (filter) {
  PriorityFilter.all => true,
  PriorityFilter.p0 => item.priority == CapturePriority.p0,
  PriorityFilter.p1 => item.priority == CapturePriority.p1,
  PriorityFilter.p2 => item.priority == CapturePriority.p2,
  PriorityFilter.p3 => item.priority == CapturePriority.p3,
  PriorityFilter.unranked => item.priority == null,
};

/// [items] in the order [sort] asks for, as a new list.
///
/// The priority order is P0 → P3, then unranked. Ties keep the incoming order,
/// which is the controller's newest-first, and that is made explicit rather
/// than left to `List.sort` — which promises no stability.
List<Recording> sortForQueue(List<Recording> items, QueueSort sort) {
  if (sort == QueueSort.newest) return List<Recording>.of(items);
  final List<(int, Recording)> indexed = <(int, Recording)>[
    for (int i = 0; i < items.length; i++) (i, items[i]),
  ];
  int rank(Recording item) =>
      item.priority?.index ?? CapturePriority.values.length;
  indexed.sort(((int, Recording) a, (int, Recording) b) {
    final int byRank = rank(a.$2).compareTo(rank(b.$2));
    return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
  });
  return <Recording>[for (final (int, Recording) entry in indexed) entry.$2];
}

/// The list's pinned section headers: one per day under [QueueSort.newest],
/// one per rank under [QueueSort.priority]. Day headers over a priority-sorted
/// list would repeat `Today` once per rank and say nothing about the order.
///
/// Like `groupByDay`, it never re-sorts: [items] must already be in the order
/// the keyboard moves through.
List<QueueDayGroup> groupForQueue(
  List<Recording> items,
  QueueSort sort,
  DateTime now,
) {
  if (sort == QueueSort.newest) return groupByDay(items, now);
  final List<QueueDayGroup> groups = <QueueDayGroup>[];
  for (final Recording item in items) {
    final String label = item.priority?.label ?? 'Unranked';
    if (groups.isEmpty || groups.last.label != label) {
      groups.add(QueueDayGroup(label, <Recording>[item]));
    } else {
      groups.last.items.add(item);
    }
  }
  return groups;
}
