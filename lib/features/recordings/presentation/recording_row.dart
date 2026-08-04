import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import 'card_parts.dart';
import 'recording_card.dart';

/// A compact queue item for narrow windows.
///
/// The collapsed row stays scannable; expanding it exposes the same durable
/// information and actions as the desktop card without forcing every item to
/// occupy a full phone screen.
class RecordingRow extends StatelessWidget {
  const RecordingRow({
    super.key,
    required this.recording,
    required this.expanded,
    required this.focused,
    required this.isPlaying,
    required this.isEnriching,
    required this.canRoute,
    required this.onTap,
    required this.onTogglePlay,
    required this.onOpen,
    required this.onRetry,
    required this.onEnrich,
    required this.onEdit,
    required this.onRoute,
    required this.onToggleProcessed,
    this.projectName,
  });

  final Recording recording;
  final bool expanded;
  final bool focused;
  final bool isPlaying;
  final bool isEnriching;
  final bool canRoute;
  final String? projectName;
  final VoidCallback onTap;
  final VoidCallback onTogglePlay;
  final VoidCallback onOpen;
  final VoidCallback onRetry;
  final VoidCallback onEnrich;
  final VoidCallback onEdit;
  final VoidCallback onRoute;
  final VoidCallback onToggleProcessed;

  static const double _indent = 16;

  @override
  Widget build(BuildContext context) {
    final bool failed = recording.status == RecordingStatus.failed;
    final bool reviewed = recording.isProcessedByUser;
    final String filename = Uri.file(recording.filePath).pathSegments.last;
    final String transcript = (recording.transcript ?? '').trim();
    final String summary = (recording.summary ?? '').trim();
    final bool hasTranscript = transcript.isNotEmpty;
    final bool openable = recording.type == CaptureType.video;

    return Semantics(
      button: true,
      expanded: expanded,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            color: expanded ? Console.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: focused
                  ? Console.cyan
                  : expanded
                  ? Console.borderStrong
                  : Colors.transparent,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _StatusDot(
                    color: failed ? Console.red : Console.cyan,
                    pulse:
                        isEnriching ||
                        recording.status == RecordingStatus.transcribing,
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
                  _CollapsedBadge(
                    recording: recording,
                    isEnriching: isEnriching,
                  ),
                  const SizedBox(width: 2),
                  _ReviewToggle(reviewed: reviewed, onTap: onToggleProcessed),
                ],
              ),
              if (expanded) ...<Widget>[
                if (summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_indent, 8, 4, 0),
                    child: Text(
                      summary,
                      style: ConsoleText.cardMeta.copyWith(
                        color: Console.textSoft,
                        height: 1.4,
                      ),
                    ),
                  ),
                if (hasTranscript)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_indent, 8, 4, 0),
                    child: Text(transcript, style: ConsoleText.body),
                  ),
                if (projectName != null || recording.tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_indent, 8, 4, 0),
                    child: Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: <Widget>[
                        if (projectName != null)
                          StatusPill(
                            label: projectName!,
                            color: Console.violet,
                            outlined: true,
                          ),
                        for (final String tag in recording.tags)
                          _TagLabel(label: tag),
                      ],
                    ),
                  ),
                if (recording.error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_indent, 8, 4, 0),
                    child: Text(
                      recording.error!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: ConsoleText.micro.copyWith(color: Console.redSoft),
                    ),
                  ),
                if (recording.routes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_indent, 8, 4, 0),
                    child: Row(
                      children: <Widget>[
                        const Icon(
                          Icons.subdirectory_arrow_right_rounded,
                          size: 13,
                          color: Console.green,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            recording.routes.last.target,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ConsoleText.micro.copyWith(
                              color: Console.green,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(_indent, 10, 4, 0),
                  child: VerificationLine(recording: recording),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(_indent, 8, 4, 0),
                  child: Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: <Widget>[
                      if (failed)
                        ConsoleIconButton(
                          icon: Icons.refresh_rounded,
                          onTap: onRetry,
                          semanticLabel: 'Retry processing',
                        ),
                      if (hasTranscript && !isEnriching)
                        ConsoleIconButton(
                          icon: Icons.auto_awesome_outlined,
                          onTap: onEnrich,
                          semanticLabel: 'Run LLM enrichment',
                        ),
                      if (recording.type.isPlayableAudio)
                        ConsoleIconButton(
                          icon: isPlaying
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          onTap: onTogglePlay,
                          semanticLabel: isPlaying
                              ? 'Stop playback'
                              : 'Play recording',
                          active: isPlaying,
                        )
                      else if (openable)
                        ConsoleIconButton(
                          icon: Icons.play_arrow_rounded,
                          onTap: onOpen,
                          semanticLabel: RecordingCard.openVideoLabel,
                        ),
                      if (canRoute && !reviewed)
                        ConsoleIconButton(
                          icon: Icons.outbound_outlined,
                          onTap: onRoute,
                          semanticLabel: RecordingCard.routeLabel,
                        ),
                      ConsoleIconButton(
                        icon: Icons.edit_outlined,
                        onTap: onEdit,
                        semanticLabel: 'Edit title and text',
                      ),
                      if (hasTranscript)
                        CopyButton(
                          text: transcript,
                          tooltip: 'Copy text',
                          semanticLabel: 'Copy text to clipboard',
                        ),
                    ],
                  ),
                ),
              ],
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
        color: Console.cyan,
        outlined: true,
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
      child: SizedBox.square(
        dimension: 44,
        child: InkResponse(
          onTap: onTap,
          radius: 22,
          child: Center(
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
                color: reviewed ? Console.green : Console.dimText,
                size: 22,
              ),
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
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Console.cyan.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Console.cyan.withValues(alpha: .22)),
      ),
      child: Text(
        '#$label',
        style: ConsoleText.micro.copyWith(color: Console.cyan),
      ),
    );
  }
}
