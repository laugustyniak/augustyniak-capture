import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import 'card_parts.dart';

/// One queue item in the **phone** layout: a dense row that opens in place.
///
/// The desktop `RecordingCard` shows everything at once because a 430 px grid
/// column has the room. A 393 px phone does not, so this row states only what
/// identifies the capture — a colour, a name, one badge and the review toggle —
/// and reveals the text, the tags and the tools when it is tapped.
///
/// Two departures from the mobile design, both deliberate:
///
/// - **The review toggle is on the collapsed row.** The design draws
///   `INBOX / DONE / ANY` tabs but no control that moves an item between them,
///   which would make the tabs unreachable state. Marking things done is the
///   loop the phone exists for, so it cannot cost a tap to reveal.
/// - **The verification line survives, on the expanded row.** `file verified ·
///   … · persisted` is this app's guarantee made visible, and the design had no
///   concept of it. Collapsing it away entirely would delete the one thing the
///   queue says that no other capture app can; putting it behind the same tap
///   as the transcript is the compromise the width forces.
class RecordingRow extends StatelessWidget {
  const RecordingRow({
    super.key,
    required this.recording,
    required this.expanded,
    required this.isPlaying,
    required this.onTap,
    required this.onTogglePlay,
    required this.onOpen,
    required this.onRetry,
    required this.onEdit,
    required this.onToggleProcessed,
    this.isEnriching = false,
    this.projectName,
  });

  final Recording recording;

  /// This row is the one currently opened. Exactly one is, which is what keeps
  /// the list scannable — an accordion, not a set of checkboxes.
  final bool expanded;
  final bool isPlaying;
  final bool isEnriching;
  final String? projectName;

  final VoidCallback onTap;
  final VoidCallback onTogglePlay;
  final VoidCallback onOpen;
  final VoidCallback onRetry;
  final VoidCallback onEdit;
  final VoidCallback onToggleProcessed;

  /// Indent shared by the meta line and the expanded body, so everything under
  /// the title hangs off the same edge rather than off the dot.
  static const double _indent = 16;

  @override
  Widget build(BuildContext context) {
    final bool failed = recording.status == RecordingStatus.failed;
    final String filename = Uri.file(recording.filePath).pathSegments.last;
    final String? title = recording.title?.trim();
    final String displayName = (title == null || title.isEmpty)
        ? filename
        : title;
    final String transcript = recording.transcript ?? '';
    final bool hasTranscript = transcript.trim().isNotEmpty;
    final bool openable = recording.type == CaptureType.video;
    final Color accent = _accent(failed);

    return Semantics(
      button: true,
      expanded: expanded,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            // A collapsed row has no card around it at all: forty bordered
            // boxes down a phone screen read as forty objects to deal with,
            // where forty lines read as a list. The border arrives with the
            // opened row, and marks it.
            color: expanded ? Console.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: expanded ? Console.borderBright : Colors.transparent,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _Dot(color: accent, pulse: _pulses),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ConsoleText.cardTitle.copyWith(fontSize: 13.5),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _CollapsedBadge(
                    recording: recording,
                    isEnriching: isEnriching,
                  ),
                  const SizedBox(width: 6),
                  _ReviewToggle(
                    reviewed: recording.isProcessedByUser,
                    onTap: onToggleProcessed,
                  ),
                ],
              ),
              if (expanded) ...<Widget>[
                if (hasTranscript)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_indent, 7, 0, 0),
                    child: Text(transcript, style: ConsoleText.body),
                  ),
                if (projectName != null || recording.tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_indent, 8, 0, 0),
                    child: Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        if (projectName != null)
                          StatusPill(
                            label: projectName!,
                            color: Console.violet,
                          ),
                        for (final String tag in recording.tags)
                          _TagLabel(label: tag),
                      ],
                    ),
                  ),
                if (recording.error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_indent, 8, 0, 0),
                    child: Text(
                      recording.error!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: ConsoleText.micro.copyWith(color: Console.redSoft),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(_indent, 10, 0, 0),
                  child: Row(
                    children: <Widget>[
                      Expanded(child: VerificationLine(recording: recording)),
                      if (failed) ...<Widget>[
                        ConsoleIconButton(
                          icon: Icons.refresh_rounded,
                          onTap: onRetry,
                          semanticLabel: 'Retry processing',
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (recording.type.isPlayableAudio) ...<Widget>[
                        ConsoleIconButton(
                          icon: isPlaying
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          onTap: onTogglePlay,
                          semanticLabel: isPlaying
                              ? 'Stop playback'
                              : 'Play recording',
                          active: isPlaying,
                        ),
                        const SizedBox(width: 6),
                      ] else if (openable) ...<Widget>[
                        ConsoleIconButton(
                          icon: Icons.play_arrow_rounded,
                          onTap: onOpen,
                          semanticLabel: RecordingRow.openVideoLabel,
                        ),
                        const SizedBox(width: 6),
                      ],
                      ConsoleIconButton(
                        icon: Icons.edit_outlined,
                        onTap: onEdit,
                        semanticLabel: 'Edit title and text',
                      ),
                      if (hasTranscript) ...<Widget>[
                        const SizedBox(width: 6),
                        CopyButton(text: transcript),
                      ],
                    ],
                  ),
                ),
              ],
              Padding(
                // Always last, collapsed or not: the timestamp is how two
                // similarly-named captures are told apart, and it is the one
                // fact the row must never hide.
                padding: const EdgeInsets.only(left: _indent, top: 5),
                child: Text(
                  metaLineFor(recording, filename),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConsoleText.cardMeta.copyWith(fontSize: 9.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Shared with the desktop card so a screen reader hears one action name for
  /// the same thing on both layouts.
  static const String openVideoLabel = 'Open video externally';

  /// The dot is the row's whole status display when it is collapsed, so it
  /// carries whichever fact is most urgent: a failure first, then the category
  /// the item was routed to, then the resting accent.
  Color _accent(bool failed) {
    if (failed) return Console.red;
    if (recording.category != null) {
      return categoryColorFor(recording.category!);
    }
    return Console.cyan;
  }

  bool get _pulses =>
      isEnriching || recording.status == RecordingStatus.transcribing;
}

/// The category/status colour, as an 8 px disc. Pulses while something is
/// actively running on the item — the row's stand-in for the card's progress
/// bar, which has nowhere to live at this density.
class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.pulse});

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

/// One badge, never two.
///
/// The desktop card has room for the category *and* the pipeline status; a
/// phone row does not, and showing both would push the title into an ellipsis
/// two words in. So the row shows whichever is still news: while the pipeline
/// is doing something the pipeline wins, and once the item is finished the
/// category — the thing the user is actually sorting by — takes over.
class _CollapsedBadge extends StatelessWidget {
  const _CollapsedBadge({required this.recording, required this.isEnriching});

  final Recording recording;
  final bool isEnriching;

  @override
  Widget build(BuildContext context) {
    if (isEnriching) {
      return const StatusPill(
        label: 'ANALYZING',
        color: Console.cyan,
        pulse: true,
      );
    }
    if (recording.status != RecordingStatus.completed) {
      final (String label, Color color) = switch (recording.status) {
        RecordingStatus.saved => ('RAW', Console.muted),
        RecordingStatus.pendingTranscription => ('QUEUED', Console.amber),
        RecordingStatus.transcribing => ('TRANSCRIBING', Console.cyan),
        RecordingStatus.failed => ('FAILED', Console.red),
        RecordingStatus.completed => ('READY', Console.green),
      };
      return StatusPill(label: label, color: color);
    }
    if (recording.category != null) {
      return StatusPill(
        label: recording.category!.label,
        color: categoryColorFor(recording.category!),
      );
    }
    return const StatusPill(label: 'READY', color: Console.green);
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
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: Padding(
          // Pads a 20 px glyph out to a 44 px target without making the row
          // taller — the tap area overhangs the text beside it, which is fine
          // because nothing else on that side is tappable.
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            transitionBuilder: (Widget child, Animation<double> animation) =>
                ScaleTransition(
                  scale: CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutBack,
                  ),
                  child: FadeTransition(opacity: animation, child: child),
                ),
            child: Icon(
              reviewed
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              key: ValueKey<bool>(reviewed),
              color: reviewed ? Console.green : Console.dimSoft,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}

class _TagLabel extends StatelessWidget {
  const _TagLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Console.cyan.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Console.cyan.withValues(alpha: .2)),
      ),
      child: Text(
        '#$label',
        style: ConsoleText.micro.copyWith(fontSize: 9.5, color: Console.cyan),
      ),
    );
  }
}
