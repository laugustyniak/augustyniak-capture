import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_segment.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import '../domain/recording_revision.dart';
import '../domain/route_record.dart';
import 'card_parts.dart';

enum ThreadEntryKind { segment, route, revision }

/// One line of the thread: what happened, when, and how it stands.
class ThreadEntry {
  const ThreadEntry({
    required this.kind,
    required this.at,
    required this.title,
    this.status,
    this.statusColor,
  });

  final ThreadEntryKind kind;
  final DateTime at;
  final String title;

  /// Pill text, when the entry has a state to report.
  final String? status;
  final Color Function()? statusColor;
}

/// The story of one capture in order, oldest first: its fragments, its
/// deliveries and the edits made to it.
///
/// Pure view composition over what the row and the revisions log already hold;
/// it persists nothing and adds no field. Every entry type has a timestamp on
/// disk (`CaptureSegment.createdAt`, `RouteRecord.at`, `RecordingRevision.at`),
/// so the order is real time. Equal timestamps fall back to list position —
/// segments, then routes, then revisions, each in its own list order. Not
/// `const`: it paints palette colours.
class CaptureThread extends StatefulWidget {
  CaptureThread({super.key, required this.recording, required this.revisions});

  final Recording recording;

  /// Read from `RecordingsController.revisionsFor`, which is an in-memory
  /// lookup: the panel never waits on it.
  final List<RecordingRevision> revisions;

  /// Entries kept while collapsed.
  static const int collapsedCount = 5;

  static const Key boundaryKey = Key('capture-thread');
  static const Key entryKey = Key('capture-thread-entry');
  static const Key entryTitleKey = Key('capture-thread-entry-title');

  /// A capture with only its own first segment has no story to tell.
  static bool appliesTo(List<ThreadEntry> entries) => entries.length > 1;

  static List<ThreadEntry> entriesFor(
    Recording recording,
    List<RecordingRevision> revisions,
  ) {
    final List<ThreadEntry> entries = <ThreadEntry>[
      for (final CaptureSegment segment in recording.segments)
        _segmentEntry(segment),
      for (final RouteRecord route in recording.routes) _routeEntry(route),
      for (final RecordingRevision revision in revisions)
        _revisionEntry(revision),
    ];
    // `List.sort` is not stable; the position is the explicit tie-break.
    final List<int> order = List<int>.generate(entries.length, (int i) => i)
      ..sort((int a, int b) {
        final int byTime = entries[a].at.compareTo(entries[b].at);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    return <ThreadEntry>[for (final int i in order) entries[i]];
  }

  static String typeLabel(CaptureType type) => switch (type) {
    CaptureType.audioRecording => 'voice note',
    CaptureType.audioUpload => 'audio file',
    CaptureType.image => 'image',
    CaptureType.text => 'note',
    CaptureType.video => 'video',
    CaptureType.file => 'file',
  };

  static ThreadEntry _segmentEntry(CaptureSegment segment) {
    final String type = typeLabel(segment.type);
    final (String, Color Function()) status = segment.error != null
        ? ('FAILED', () => Console.red)
        : segment.isPending
        ? ('PENDING', () => Console.muted)
        : ('DONE', () => Console.green);
    return ThreadEntry(
      kind: ThreadEntryKind.segment,
      at: segment.createdAt,
      title: segment.index == 0
          ? 'Capture · $type'
          : 'Fragment ${segment.index} · $type',
      status: status.$1,
      statusColor: status.$2,
    );
  }

  static ThreadEntry _routeEntry(RouteRecord route) {
    final CommandState? state = route.outcome?.state;
    return ThreadEntry(
      kind: ThreadEntryKind.route,
      at: route.at,
      title: route.target,
      status: state == null ? null : commandStateLabel(state),
      statusColor: state == null ? null : () => _stateColor(state),
    );
  }

  static ThreadEntry _revisionEntry(RecordingRevision revision) => ThreadEntry(
    kind: ThreadEntryKind.revision,
    at: revision.at,
    title: '${revision.field} changed',
    status: revision.source.label,
    statusColor: () => Console.muted,
  );

  static Color _stateColor(CommandState state) => switch (state) {
    CommandState.done => Console.green,
    CommandState.blocked => Console.red,
    CommandState.needsReview => Console.violet,
    CommandState.inProgress => Console.accent,
    _ => Console.muted,
  };

  @override
  State<CaptureThread> createState() => _CaptureThreadState();
}

class _CaptureThreadState extends State<CaptureThread> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final List<ThreadEntry> entries = CaptureThread.entriesFor(
      widget.recording,
      widget.revisions,
    );
    if (!CaptureThread.appliesTo(entries)) return const SizedBox.shrink();

    final bool collapsible = entries.length > CaptureThread.collapsedCount;
    final List<ThreadEntry> shown = collapsible && !_showAll
        ? entries.sublist(entries.length - CaptureThread.collapsedCount)
        : entries;

    return RepaintBoundary(
      key: CaptureThread.boundaryKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SectionHeader(
            title: 'THREAD',
            trailing:
                '${entries.length} entr${entries.length == 1 ? 'y' : 'ies'}',
          ),
          const SizedBox(height: 8),
          for (final ThreadEntry entry in shown) _ThreadTile(entry: entry),
          if (collapsible)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _showAll = !_showAll),
                child: Text(
                  _showAll ? 'show less' : 'show all (${entries.length})',
                  style: ConsoleText.micro.copyWith(color: Console.accent),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  _ThreadTile({required this.entry});

  final ThreadEntry entry;

  IconData get _icon => switch (entry.kind) {
    ThreadEntryKind.segment => Icons.circle_outlined,
    ThreadEntryKind.route => Icons.subdirectory_arrow_right_rounded,
    ThreadEntryKind.revision => Icons.edit_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final String? status = entry.status;
    return Padding(
      key: CaptureThread.entryKey,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(_icon, size: 14, color: Console.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.title,
              key: CaptureThread.entryTitleKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ConsoleText.body.copyWith(
                fontSize: 13,
                color: Console.text,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(formatDateTime(entry.at), style: ConsoleText.micro),
          if (status != null) ...<Widget>[
            const SizedBox(width: 8),
            StatusPill(label: status, color: entry.statusColor!()),
          ],
        ],
      ),
    );
  }
}
