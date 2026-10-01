import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../settings/domain/queue_density.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import 'card_parts.dart';

/// One capture in the master list of the wide Queue.
///
/// A row is for *finding* a capture, never for acting on it: every action, the
/// transcript, the durability line and the copy buttons live in the detail
/// panel beside the list. What stays is exactly what tells two neighbours
/// apart at a glance — the category dot, the title, up to three tags, one
/// summary line, the project and two mono columns of time.
///
/// Colour appears in one place only, the dot. A tinted title or row
/// background would make the colour of a category louder than the capture
/// itself.
class QueueListRow extends StatelessWidget {
  QueueListRow({
    super.key,
    required this.recording,
    required this.selected,
    required this.isEnriching,
    required this.density,
    required this.onTap,
    this.projectName,
  });

  final Recording recording;
  final bool selected;
  final bool isEnriching;
  final QueueDensity density;
  final VoidCallback onTap;
  final String? projectName;

  /// Rendered instead of the summary while the model reads the capture, so a
  /// row that is about to change says so instead of showing a stale line.
  static const String analyzingLine =
      'Analyzing: title, category, summary, tags';

  static const double _projectWidth = 120;
  static const double _durationWidth = 48;
  static const double _timeWidth = 56;
  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    final bool comfortable = density == QueueDensity.comfortable;
    final bool failed = recording.status == RecordingStatus.failed;
    final bool processing =
        isEnriching || recording.status == RecordingStatus.transcribing;
    final TextStyle monoStyle = ConsoleText.cardMeta.copyWith(
      color: Console.muted,
    );

    return Semantics(
      button: true,
      selected: selected,
      label: displayNameFor(recording),
      excludeSemantics: true,
      child: Material(
        color: selected
            ? Console.accent.withValues(alpha: .10)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: Console.surfaceRaised,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: comfortable ? 14 : 8,
            ),
            decoration: BoxDecoration(
              border: selected
                  ? Border.all(color: Console.accent.withValues(alpha: .30))
                  : Border(
                      bottom: BorderSide(
                        color: Console.border.withValues(alpha: .6),
                      ),
                    ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                _Dot(
                  // State outranks label, as on the phone row: a failure or a
                  // job still running is the thing that changes, so it takes
                  // the one colour this row spends.
                  color: failed
                      ? Console.red
                      : processing ||
                            recording.status != RecordingStatus.completed
                      ? Console.accent
                      : categoryColorFor(recording.category),
                  pulse: processing,
                ),
                const SizedBox(width: _gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _TitleLine(recording: recording),
                      const SizedBox(height: 3),
                      Text(
                        _secondLine(),
                        maxLines: comfortable ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: ConsoleText.body.copyWith(
                          fontSize: 13,
                          height: 1.45,
                          color: failed ? Console.redSoft : Console.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: _projectWidth,
                  child: Text(
                    projectName ?? '—',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ConsoleText.body.copyWith(
                      fontSize: 12,
                      color: Console.muted,
                    ),
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: _durationWidth,
                  child: Text(
                    _duration(),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    style: monoStyle,
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: _timeWidth,
                  child: Text(
                    formatTimeOfDay(recording.createdAt),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    style: monoStyle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The summary when there is one; otherwise the stage the capture is in, so
  /// an un-enriched row still says something a neighbour does not.
  String _secondLine() {
    if (isEnriching) return analyzingLine;
    switch (recording.status) {
      case RecordingStatus.saved:
        return 'Saved and verified · not handed to a processor yet';
      case RecordingStatus.pendingTranscription:
        return 'Queued for processing';
      case RecordingStatus.transcribing:
        return recording.type == CaptureType.image
            ? 'Extracting text from image…'
            : 'Transcribing speech to text…';
      case RecordingStatus.failed:
        return recording.error?.trim().isNotEmpty == true
            ? recording.error!.trim()
            : 'Processing failed · the source file is intact';
      case RecordingStatus.completed:
        break;
    }
    final String summary = (recording.summary ?? '').trim();
    if (summary.isNotEmpty) return summary;
    final String transcript = (recording.transcript ?? '').trim();
    if (transcript.isNotEmpty) return transcript.replaceAll('\n', ' ');
    return 'No text';
  }

  String _duration() {
    if (!recording.type.hasDuration || recording.totalDurationMs <= 0) {
      return '';
    }
    return formatDuration(Duration(milliseconds: recording.totalDurationMs));
  }
}

class _TitleLine extends StatelessWidget {
  _TitleLine({required this.recording});

  final Recording recording;

  @override
  Widget build(BuildContext context) {
    final List<String> tags = recording.tags;
    final String tagLine = <String>[
      for (final String tag in tags.take(3)) '#$tag',
      if (tags.length > 3) '+${tags.length - 3}',
    ].join('  ');
    // Tags give way to the title, never the reverse: they get at most 40% of
    // the line, so a narrow list keeps the title legible and drops tags into
    // the ellipsis first.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Flexible(
            child: Text(
              displayNameFor(recording),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ConsoleText.cardTitle.copyWith(fontSize: 14),
            ),
          ),
          if (tagLine.isNotEmpty) ...<Widget>[
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (constraints.maxWidth * .4).clamp(0, 260),
              ),
              child: Text(
                tagLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ConsoleText.body.copyWith(
                  fontSize: 12,
                  color: Console.muted,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  _Dot({required this.color, required this.pulse});

  final Color color;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    if (pulse) return PulseDot(color: color, size: 8);
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// The sticky day label above a run of rows: `TODAY`, `YESTERDAY`, `29 SEP`.
class QueueDayHeader extends StatelessWidget {
  QueueDayHeader({super.key, required this.label});

  static const double height = 28;

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Console.background,
        border: Border(
          bottom: BorderSide(color: Console.border.withValues(alpha: .6)),
        ),
      ),
      child: Text(
        label.toUpperCase(),
        style: ConsoleText.micro.copyWith(
          fontSize: 11,
          letterSpacing: 1.3,
          color: Console.muted,
        ),
      ),
    );
  }
}

const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `Today`, `Yesterday`, `29 Sep`, or `29 Sep 2025` outside the current year.
/// Compared on local calendar days, never on a 24-hour difference, so a
/// capture from 23:50 is "yesterday" ten minutes later.
String queueDayLabel(DateTime value, DateTime now) {
  final DateTime day = DateUtils.dateOnly(value.toLocal());
  final DateTime today = DateUtils.dateOnly(now.toLocal());
  if (day == today) return 'Today';
  // Calendar arithmetic, not `subtract(Duration(days: 1))`: across a DST
  // change a 24-hour step lands at 23:00 or 01:00 and never equals a date.
  if (day == DateTime(today.year, today.month, today.day - 1)) {
    return 'Yesterday';
  }
  final String base = '${day.day} ${_months[day.month - 1]}';
  return day.year == today.year ? base : '$base ${day.year}';
}

/// A run of consecutive captures from one local day, in list order.
class QueueDayGroup {
  QueueDayGroup(this.label, this.items);

  final String label;
  final List<Recording> items;
}

/// Splits [items] into runs of the same local day **without re-sorting**:
/// the list order is the controller's, and the master list must agree with
/// the order the keyboard moves through.
List<QueueDayGroup> groupByDay(List<Recording> items, DateTime now) {
  final List<QueueDayGroup> groups = <QueueDayGroup>[];
  for (final Recording item in items) {
    final String label = queueDayLabel(item.createdAt, now);
    if (groups.isEmpty || groups.last.label != label) {
      groups.add(QueueDayGroup(label, <Recording>[item]));
    } else {
      groups.last.items.add(item);
    }
  }
  return groups;
}
