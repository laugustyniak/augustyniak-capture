import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import 'card_parts.dart';

/// One queue item, in the design's "console card" form.
///
/// Reads top to bottom as the pipeline does: what was captured (tile, name,
/// facts), where it is now (status pill), what came out of it (excerpt), and
/// the durability guarantee underneath (`file verified · … · persisted`). That
/// last line is the whole point of the app made visible, so it is present on
/// every card including failed ones — a processing failure never costs you the
/// source.
class RecordingCard extends StatelessWidget {
  const RecordingCard({
    super.key,
    required this.recording,
    required this.isPlaying,
    this.isEnriching = false,
    this.projectName,
    required this.onTogglePlay,
    required this.onOpen,
    required this.onRetry,
    required this.onEdit,
    required this.onToggleProcessed,
  });

  /// Said in both places the action is offered — the poster and the button —
  /// so a screen reader announces one action, not two different-sounding ones.
  /// It names the *destination* deliberately: unlike audio, this leaves the
  /// app. Public so a test cannot drift from the string it asserts on.
  static const String openVideoLabel = 'Open video externally';

  /// Names the four fields the enrichment pass can fill, so the animation says
  /// *what* is being analysed rather than just that something is. Public for
  /// the same reason as [openVideoLabel].
  static const String analyzingLabel =
      'analyzing text · title, category, summary, tags';

  final Recording recording;
  final bool isPlaying;

  /// The second AI stage is reading this item's text right now. Not a
  /// [RecordingStatus]: the item is already `completed` and on disk, so this
  /// only ever changes what the card *says is happening*, never what the queue
  /// considers finished — a card in this state stays in the READY bucket and
  /// keeps every control it had.
  final bool isEnriching;

  /// Resolved name of the item's project, or null when it has none. Resolved by
  /// the caller rather than looked up here: the card never reaches past the
  /// item it was handed, and a dangling id is the queue's problem to name.
  final String? projectName;

  final VoidCallback onTogglePlay;

  /// Hands the source to the platform's own player/viewer. Deliberately not
  /// folded into [onTogglePlay]: audio plays *in* the app and is stateful
  /// ([isPlaying] drives the stop icon), while a video is an external launch
  /// with no state to come back to. One callback would have to lie about one
  /// of the two.
  final VoidCallback onOpen;
  final VoidCallback onRetry;
  final VoidCallback onEdit;
  final VoidCallback onToggleProcessed;

  @override
  Widget build(BuildContext context) {
    final bool failed = recording.status == RecordingStatus.failed;
    final bool reviewed = recording.isProcessedByUser;
    // Enrichment cannot move the status — the item is already `completed` — but
    // the pill is the one place the user looks to find out what is going on, so
    // while the model reads the text it says that rather than the resting READY.
    final _StatusVisual visual = isEnriching
        ? const _StatusVisual('ANALYZING', Console.cyan, pulse: true)
        : _statusVisual(recording.status);
    final String filename = File(recording.filePath).uri.pathSegments.last;
    final String? title = recording.title?.trim();
    final bool hasTitle = title != null && title.isNotEmpty;
    final String displayName = hasTitle ? title : filename;
    // Generic processor output: a transcription, OCR text or a note body.
    final String transcript = recording.transcript ?? '';
    final bool hasTranscript = transcript.trim().isNotEmpty;
    final bool openable = recording.type == CaptureType.video;

    return RecordingCardShell(
      borderColor: failed
          ? Console.red.withValues(alpha: .35)
          : reviewed
          ? Console.cyan.withValues(alpha: .35)
          : Console.border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              RecordingLeadingTile(
                recording: recording,
                failed: failed,
                onOpen: openable ? onOpen : null,
                semanticLabel: RecordingCard.openVideoLabel,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ConsoleText.cardTitle,
                          ),
                        ),
                        if (reviewed) ...<Widget>[
                          const SizedBox(width: 7),
                          const Icon(
                            Icons.check_circle_outline_rounded,
                            size: 14,
                            color: Console.cyan,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      metaLineFor(recording, filename),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ConsoleText.cardMeta,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Two pills, one row: what the item *is* and where it is in the
              // pipeline. Reuses StatusPill rather than adding a widget — the
              // colour is what tells them apart. The category is absent until
              // enrichment has run, so an install with no enrichment profile
              // renders exactly the card it rendered before.
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (projectName != null)
                    StatusPill(label: projectName!, color: Console.violet),
                  if (recording.category != null)
                    StatusPill(
                      label: recording.category!.label,
                      color: Console.mutedSoft,
                    ),
                  // Cross-faded rather than swapped: READY → ANALYZING →
                  // READY happens twice within a couple of seconds, and a
                  // hard cut at that rate reads as the card glitching.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    child: StatusPill(
                      key: ValueKey<String>(visual.label),
                      label: visual.label,
                      color: visual.color,
                      pulse: visual.pulse,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if ((recording.summary ?? '').trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 9),
            Text(
              recording.summary!.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ConsoleText.cardMeta.copyWith(color: Console.textSoft),
            ),
          ],
          if (recording.tags.isNotEmpty) ...<Widget>[
            const SizedBox(height: 9),
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: <Widget>[
                for (final String tag in recording.tags) _TagLabel(tag: tag),
              ],
            ),
          ],
          if (recording.status == RecordingStatus.transcribing) ...<Widget>[
            const SizedBox(height: 12),
            const ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(2)),
              child: LinearProgressIndicator(
                minHeight: 3,
                color: Console.cyan,
                backgroundColor: Console.track,
              ),
            ),
          ],
          // Sits above the excerpt on purpose: it is a statement about the
          // text underneath it — the model is reading exactly that.
          if (isEnriching) ...<Widget>[
            const SizedBox(height: 12),
            const _EnrichingStrip(),
          ],
          if (hasTranscript) ...<Widget>[
            const SizedBox(height: 11),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(
                    transcript,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: ConsoleText.body,
                  ),
                ),
                const SizedBox(width: 8),
                // Copies the whole text, not the three lines rendered above.
                CopyButton(
                  text: transcript,
                  tooltip: 'Copy text',
                  semanticLabel: 'Copy text to clipboard',
                ),
              ],
            ),
          ],
          if (recording.error != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              recording.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ConsoleText.micro.copyWith(color: Console.redSoft),
            ),
          ],
          const SizedBox(height: 11),
          Row(
            children: <Widget>[
              Expanded(child: VerificationLine(recording: recording)),
              const SizedBox(width: 8),
              if (failed) ...<Widget>[
                _GhostButton(
                  icon: Icons.refresh_rounded,
                  label: 'RETRY',
                  onTap: onRetry,
                ),
                const SizedBox(width: 8),
              ],
              // In-app playback is audio-only; text and image items have no
              // track at all.
              if (recording.type.isPlayableAudio) ...<Widget>[
                ConsoleIconButton(
                  icon: isPlaying
                      ? Icons.stop_rounded
                      : Icons.play_arrow_rounded,
                  onTap: onTogglePlay,
                  semanticLabel: isPlaying ? 'Stop playback' : 'Play recording',
                  active: isPlaying,
                  size: 30,
                  iconSize: 18,
                ),
                const SizedBox(width: 7),
              ]
              // A video leaves the app to play: there is no in-process video
              // widget on the desktop targets, so this hands the file to
              // whatever the user already has. Nothing to stop afterwards,
              // hence no `active` state and a fixed icon.
              else if (openable) ...<Widget>[
                ConsoleIconButton(
                  icon: Icons.play_arrow_rounded,
                  onTap: onOpen,
                  semanticLabel: RecordingCard.openVideoLabel,
                  size: 30,
                  iconSize: 18,
                ),
                const SizedBox(width: 7),
              ],
              ConsoleIconButton(
                icon: Icons.edit_outlined,
                onTap: onEdit,
                semanticLabel: 'Edit title and text',
                size: 30,
                iconSize: 16,
              ),
              const SizedBox(width: 7),
              _ReviewToggle(reviewed: reviewed, onTap: onToggleProcessed),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the enrichment pass is doing, while it does it: a label naming the four
/// fields it can fill, over a band of light sweeping the text below.
///
/// The label is what carries the meaning — the sweep alone would only say
/// "busy", and this stage is easy to mistake for the transcription that just
/// finished. Public through [RecordingCard.analyzingLabel] so a test cannot
/// drift from the string that is actually rendered.
class _EnrichingStrip extends StatelessWidget {
  const _EnrichingStrip();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(
              Icons.auto_awesome_outlined,
              size: 12,
              color: Console.cyan,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                RecordingCard.analyzingLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ConsoleText.micro.copyWith(color: Console.cyan),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        const ScanLine(),
      ],
    );
  }
}

/// Outlined text button used for the one recovery action a card can offer.
class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Console.borderStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 12, color: Console.text),
              const SizedBox(width: 6),
              Text(
                label,
                style: ConsoleText.chip.copyWith(color: Console.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The done flag. Deliberately the last control on the row and the only one
/// that is never gated on status: completion is a user-owned axis, independent
/// of whatever the processing pipeline is doing to the item.
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
        radius: 22,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          transitionBuilder: (Widget child, Animation<double> animation) {
            return ScaleTransition(
              scale: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutBack,
              ),
              child: FadeTransition(opacity: animation, child: child),
            );
          },
          child: Icon(
            reviewed
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            key: ValueKey<bool>(reviewed),
            color: reviewed ? Console.green : Console.dimText,
            size: 26,
          ),
        ),
      ),
    );
  }
}

/// One tag, as the card shows it. There is only one kind: a tag proposed by
/// enrichment and a tag typed by hand are the same object, so they render the
/// same way. Two colours here used to mean two owners, which made the reader
/// answer "who typed this?" before they could read the word.
class _TagLabel extends StatelessWidget {
  const _TagLabel({required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Console.cyan.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Console.cyan.withValues(alpha: .22)),
      ),
      child: Text(
        '#$tag',
        style: ConsoleText.micro.copyWith(color: Console.cyan),
      ),
    );
  }
}

class _StatusVisual {
  const _StatusVisual(this.label, this.color, {this.pulse = false});
  final String label;
  final Color color;
  final bool pulse;
}

_StatusVisual _statusVisual(RecordingStatus status) => switch (status) {
  // Persisted but not yet handed to a processor — the design calls it RAW.
  RecordingStatus.saved => const _StatusVisual('RAW', Console.muted),
  RecordingStatus.pendingTranscription => const _StatusVisual(
    'QUEUED',
    Console.amber,
  ),
  RecordingStatus.transcribing => const _StatusVisual(
    'TRANSCRIBING',
    Console.cyan,
    pulse: true,
  ),
  RecordingStatus.completed => const _StatusVisual('READY', Console.green),
  RecordingStatus.failed => const _StatusVisual('FAILED', Console.red),
};
