import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../../gamification/presentation/done_burst_animation.dart';
import '../domain/recording.dart';
import 'card_parts.dart';

/// One queue item on a narrow window.
///
/// The row is a single line and stays that way: tapping it opens the capture's
/// focus view, which is where its summary, tags, text and every action live.
/// It used to be an accordion instead, revealing all of that in place — two
/// surfaces showing one capture, of which only the phone's had to be kept in
/// step with the card by hand. One destination is also one gesture: the same
/// tap opens a capture here and on the desktop card.
class RecordingRow extends StatelessWidget {
  const RecordingRow({
    super.key,
    required this.recording,
    required this.focused,
    required this.isEnriching,
    required this.onTap,
    required this.onToggleProcessed,
  });

  final Recording recording;
  final bool focused;
  final bool isEnriching;

  /// Opens the capture. Not a toggle any more — see the class doc.
  final VoidCallback onTap;
  final VoidCallback onToggleProcessed;

  static const double _indent = 16;

  @override
  Widget build(BuildContext context) {
    final bool failed = recording.status == RecordingStatus.failed;
    final bool reviewed = recording.isProcessedByUser;
    final String filename = Uri.file(recording.filePath).pathSegments.last;
    // The two stages that are actually running. `pendingTranscription` is not
    // one of them: an item waiting its turn behind the single-flight drain is
    // not moving, and animating it would claim work that has not started.
    final bool processing =
        isEnriching || recording.status == RecordingStatus.transcribing;

    return Semantics(
      button: true,
      label: 'Open capture',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            // A row with work running on it lifts off the page even when it is
            // off screen-centre. The 180 ms tween is what makes the end of a
            // stage read as the row settling rather than as the list
            // repainting.
            color: processing
                ? Console.accent.withValues(alpha: .05)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: focused
                  ? Console.accent
                  : processing
                  ? Console.accent.withValues(alpha: .28)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _StatusDot(
                    // State outranks label, the same way the card's filled pill
                    // does: a failure and a job still running are things that
                    // change, and they have to win the one colour this row can
                    // spare. Everything at rest is scanned by its category —
                    // which, unlike the old flat accent, is what makes a column
                    // of nine rows sortable by eye.
                    color: failed
                        ? Console.red
                        : recording.status != RecordingStatus.completed
                        ? Console.accent
                        : categoryColorFor(recording.category),
                    pulse: processing,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      displayNameFor(recording),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ConsoleText.cardTitle.copyWith(fontSize: 13.5),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Silent while the strip below is up: the two would print
                  // TRANSCRIBING twice in the same accent on a 393 px row,
                  // which reads as the row stuttering rather than as one state.
                  // The strip wins because it carries the animation as well as
                  // the word, and the badge has nothing to add to it.
                  if (!processing)
                    _CollapsedBadge(recording: recording)
                  else
                    const SizedBox.shrink(),
                  const SizedBox(width: 2),
                  _ReviewToggle(reviewed: reviewed, onTap: onToggleProcessed),
                ],
              ),
              // The phone form shows nine rows of one line each, and a capture
              // being transcribed or read by the model is the one row worth
              // finding without opening anything. The pill above says *what*
              // stage it is; this says it is still moving.
              if (processing)
                Padding(
                  padding: const EdgeInsets.fromLTRB(_indent, 9, 4, 2),
                  child: ProcessingStrip(enriching: isEnriching),
                ),
              Padding(
                padding: const EdgeInsets.only(left: _indent, top: 5, right: 4),
                child: Text(
                  metaLineFor(recording, filename),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // `muted` clears AA on the card and stays distinct from the
                  // primary title; never use the graphics-only `dim` here.
                  style: ConsoleText.cardMeta.copyWith(
                    fontSize: 9.5,
                    color: Console.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color, required this.pulse});

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

/// The resting label on a collapsed row: what the item *is*, or why it is not
/// ready. The two running stages are drawn by [ProcessingStrip] instead — see
/// the call site.
class _CollapsedBadge extends StatelessWidget {
  const _CollapsedBadge({required this.recording});

  final Recording recording;

  @override
  Widget build(BuildContext context) {
    if (recording.status != RecordingStatus.completed) {
      final (String label, Color color) = switch (recording.status) {
        RecordingStatus.saved => ('RAW', Console.muted),
        RecordingStatus.pendingTranscription => ('QUEUED', Console.amber),
        RecordingStatus.transcribing => ('TRANSCRIBING', Console.accent),
        RecordingStatus.failed => ('FAILED', Console.red),
        RecordingStatus.completed => ('READY', Console.green),
      };
      return StatusPill(label: label, color: color);
    }
    if (recording.category != null) {
      return StatusPill(
        label: recording.category!.label,
        color: categoryColorFor(recording.category),
        outlined: true,
      );
    }
    return StatusPill(label: 'READY', color: Console.green);
  }
}

class _ReviewToggle extends StatelessWidget {
  const _ReviewToggle({required this.reviewed, required this.onTap});

  final bool reviewed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      checked: reviewed,
      label: reviewed ? 'Mark as not done' : 'Mark as done',
      child: SizedBox.square(
        dimension: 44,
        child: InkResponse(
          onTap: () {
            if (!reviewed) {
              HapticFeedback.mediumImpact();
            }
            onTap();
          },
          radius: 22,
          child: Center(
            child: DoneBurstAnimation(
              reviewed: reviewed,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                transitionBuilder:
                    (Widget child, Animation<double> animation) =>
                        ScaleTransition(
                          scale: CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutBack,
                          ),
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        ),
                child: Icon(
                  reviewed
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  key: ValueKey<bool>(reviewed),
                  color: reviewed ? Console.green : Console.dimText,
                  size: 22,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
