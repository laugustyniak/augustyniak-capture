import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../../gamification/presentation/done_burst_animation.dart';
import '../domain/agent_artifact.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import '../domain/route_record.dart';
import 'card_parts.dart';
import 'transcript_focus_modal.dart';

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
    this.isMarkingDone = false,
    this.projectName,
    required this.onTogglePlay,
    required this.onOpen,
    required this.onRetry,
    required this.onEnrich,
    required this.onEdit,
    required this.onToggleProcessed,
    required this.onRoute,
    this.canRoute = false,
    required this.onHandoff,
    this.canHandoff = false,
    this.onSelectArtifact,
    this.onOpenOutcome,
    this.canOpenOutcome,
    this.focused = false,
    this.costUsd,
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

  /// Names the destination, not the gesture: this is the one control that takes
  /// a capture out of the app, and "route" alone says nothing about where.
  ///
  /// "Hand off" also absorbs the old trailing `and close`: the item leaving the
  /// user's desk *is* what closing means here, so stating it twice only invited
  /// the reader to look for a second effect.
  static const String routeLabel = "Hand off to the project's inbox";

  /// The second destination, and the one that does something rather than
  /// filing something — so it names the agent, not the gesture. Kept distinct
  /// from [routeLabel] in wording as well as icon: two controls that both said
  /// "hand off" would be one control the user has to guess at.
  static const String handoffLabel = 'Start a coding agent on this capture';

  final Recording recording;
  final bool isPlaying;

  /// The second AI stage is reading this item's text right now. Not a
  /// [RecordingStatus]: the item is already `completed` and on disk, so this
  /// only ever changes what the card *says is happening*, never what the queue
  /// considers finished — a card in this state stays in the READY bucket and
  /// keeps every control it had.
  final bool isEnriching;

  /// The durable review write is in flight. This is deliberately view-only:
  /// the check mark still comes from [recording.isProcessedByUser], so a slow
  /// or failed disk write can never make the card claim it is already done.
  final bool isMarkingDone;

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
  final VoidCallback onEnrich;
  final VoidCallback onEdit;
  final VoidCallback onToggleProcessed;

  /// Sends the capture to its project's inbox and closes it in one gesture.
  final VoidCallback onRoute;

  /// Whether the item has a destination at all. False hides the control rather
  /// than disabling it: a permanently greyed button on every capture of an
  /// install with no projects is noise that never becomes an action.
  final bool canRoute;

  /// Opens the handoff sheet — agent, prompt, launch. Unlike [onRoute] this one
  /// deliberately does not act on the tap: it starts a process on the user's
  /// machine, and which agent gets the work is a decision about the task rather
  /// than a setting to be read silently off the project.
  final VoidCallback onHandoff;

  /// Whether any agent can be started for this capture. Hidden when false, for
  /// the same reason as [canRoute] — an install with no repository configured
  /// would otherwise carry a dead button on every row.
  final bool canHandoff;
  final void Function(AgentArtifact artifact)? onSelectArtifact;

  /// Opens the delivery's own page on the control plane. Null where nothing can
  /// open a link, which renders the line dimmed rather than hiding it: what
  /// came back is worth reading even where it cannot be followed.
  final void Function(RouteOutcome outcome)? onOpenOutcome;

  /// Whether *this* outcome has somewhere to go — a pull request, or a control
  /// plane whose address is still configured. Asked per outcome rather than
  /// once for the card, because the answer differs row by row.
  final bool Function(RouteOutcome outcome)? canOpenOutcome;

  /// This row is the one the keyboard is on.
  ///
  /// Drawn on the shell's border, which is the card's single state channel, and
  /// it outranks the others: `failed` and `reviewed` are properties of the item
  /// and stay true while the user looks elsewhere, whereas this answers "where
  /// am I", and a selection the user cannot see is the same as no selection.
  final bool focused;

  /// This capture's summed usage-event cost, resolved by the caller from
  /// `UsageRepository.totalsByCapture()` — one grouped query per queue build
  /// rather than one lookup per row. Null renders `cost —` on the durability
  /// line, the same as a legacy capture that predates this feature; the card
  /// never claims a cost it was not handed.
  final double? costUsd;

  @override
  Widget build(BuildContext context) {
    final bool failed = recording.status == RecordingStatus.failed;
    final bool reviewed = recording.isProcessedByUser;
    // Enrichment cannot move the status — the item is already `completed` — but
    // the pill is the one place the user looks to find out what is going on, so
    // while the model reads the text it says that rather than the resting READY.
    final _StatusVisual? visual = isEnriching
        ? _StatusVisual('ANALYZING', Console.accent, pulse: true)
        : _statusVisual(recording.status);
    final String filename = File(recording.filePath).uri.pathSegments.last;
    final String displayName = displayNameFor(recording);
    // Generic processor output: a transcription, OCR text or a note body.
    final String transcript = recording.transcript ?? '';
    final bool hasTranscript = transcript.trim().isNotEmpty;
    final bool openable = recording.type == CaptureType.video;

    return RecordingCardShell(
      borderColor: focused
          ? Console.accent
          : failed
          ? Console.red.withValues(alpha: .35)
          : reviewed
          ? Console.accent.withValues(alpha: .35)
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
                          Icon(
                            Icons.check_circle_outline_rounded,
                            size: 14,
                            color: Console.accent,
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
              // Three facts of two different kinds. Project and category are
              // *labels* — they describe the item and do not change on their
              // own — so they are outlined; the pipeline status is the only
              // state here, and keeps the fill. Given the same form all three
              // had the same weight, and colour alone had to carry the
              // difference at 10 px.
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (projectName != null)
                    StatusPill(
                      label: projectName!,
                      // Neutral, and it has to be: violet is now `agentTask`,
                      // and the two pills sit side by side in this very Wrap —
                      // a violet outline would be read as a category by anyone
                      // scanning colour rather than text. Project is context
                      // anyway; the category is the thing to act on.
                      color: Console.mutedSoft,
                      outlined: true,
                    ),
                  if (recording.category != null)
                    StatusPill(
                      label: recording.category!.label,
                      // Raised off `mutedSoft`, which made the one field that
                      // says what to *do* with a capture the dimmest thing on
                      // the row. Category is a routing destination — and each
                      // destination now has its own colour, so the row is
                      // sortable by eye and not only by reading.
                      color: categoryColorFor(recording.category),
                      outlined: true,
                    ),
                  // Cross-faded rather than swapped: READY → ANALYZING →
                  // READY happens twice within a couple of seconds, and a
                  // hard cut at that rate reads as the card glitching.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    // The resting state draws nothing. A badge is a claim that
                    // something is different, and READY was on twenty-seven of
                    // twenty-eight rows — so the one row that was queued or had
                    // failed had to compete with a wall of green saying that
                    // everything was fine. The reviewed border and the queue's
                    // own chips already report "finished".
                    child: visual == null
                        ? const SizedBox.shrink()
                        : StatusPill(
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
          // The model's own output, and the second thing worth lifting out of
          // the app after the transcript itself: a summary is what gets pasted
          // into a standup note or a ticket. It copies in full even though the
          // card renders two lines of it — the same rule the transcript's copy
          // button already follows.
          if ((recording.summary ?? '').trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 9),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(
                    recording.summary!.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ConsoleText.cardMeta.copyWith(
                      color: Console.textSoft,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                CopyButton(
                  text: recording.summary!.trim(),
                  tooltip: 'Copy summary',
                  semanticLabel: 'Copy summary to clipboard',
                  size: 26,
                  iconSize: 13,
                ),
              ],
            ),
          ],
          if (recording.tags.isNotEmpty) ...<Widget>[
            const SizedBox(height: 9),
            Wrap(
              spacing: 6,
              runSpacing: 5,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final String tag in recording.tags) _TagLabel(tag: tag),
                CopyButton(
                  text: tagsClipboardText(recording.tags),
                  tooltip: 'Copy tags',
                  semanticLabel: 'Copy tags to clipboard',
                  size: 24,
                  iconSize: 12,
                ),
              ],
            ),
          ],
          if (recording.status == RecordingStatus.transcribing) ...<Widget>[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(2)),
              child: LinearProgressIndicator(
                minHeight: 3,
                color: Console.accent,
                backgroundColor: Console.track,
              ),
            ),
          ],
          // Sits above the excerpt on purpose: it is a statement about the
          // text underneath it — the model is reading exactly that.
          if (isEnriching) ...<Widget>[
            const SizedBox(height: 12),
            _EnrichingStrip(),
          ],
          if (hasTranscript) ...<Widget>[
            _CardTranscriptSection(
              recording: recording,
              projectName: projectName,
              onEdit: onEdit,
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
          // Where it went, which is the fact `isProcessedByUser` could never
          // carry on its own: the tick said the user was finished with the
          // item, and nothing said what they had done with it. Only the latest
          // delivery is shown — the card is not the audit trail.
          if (recording.routes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 9),
            Row(
              children: <Widget>[
                Icon(
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
                    style: ConsoleText.micro.copyWith(color: Console.green),
                  ),
                ),
              ],
            ),
            // **One line, and a link out — never a fleet view.** Command has a
            // dashboard, it installs on the same phone, and rebuilding it here
            // is the overlap this whole integration exists to avoid.
            if (recording.routes.last.outcome case final RouteOutcome outcome)
              Builder(
                builder: (BuildContext context) {
                  final bool canOpen =
                      onOpenOutcome != null &&
                      (canOpenOutcome?.call(outcome) ?? true);
                  return Padding(
                    padding: const EdgeInsets.only(top: 5, left: 18),
                    child: InkWell(
                      onTap: canOpen ? () => onOpenOutcome!(outcome) : null,
                      borderRadius: BorderRadius.circular(6),
                      child: Text(
                        outcomeLineFor(outcome),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ConsoleText.micro.copyWith(
                          color: canOpen ? Console.accent : Console.mutedSoft,
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
          if (recording.artifacts.isNotEmpty) ...<Widget>[
            const SizedBox(height: 9),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final AgentArtifact artifact in recording.artifacts)
                  InkWell(
                    onTap: () => onSelectArtifact?.call(artifact),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Console.accent.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Console.accent.withValues(alpha: .3),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            artifact.kind == AgentArtifactKind.resultNote
                                ? Icons.auto_awesome
                                : Icons.description_outlined,
                            size: 13,
                            color: Console.accent,
                          ),
                          const SizedBox(width: 5),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 180),
                            child: Text(
                              artifact.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Console.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 11),
          Row(
            children: <Widget>[
              Expanded(
                child: VerificationLine(recording: recording, costUsd: costUsd),
              ),
              const SizedBox(width: 8),
              if (failed) ...<Widget>[
                _GhostButton(
                  icon: Icons.refresh_rounded,
                  label: 'RETRY',
                  onTap: onRetry,
                ),
                const SizedBox(width: 8),
              ],
              if (hasTranscript) ...<Widget>[
                _GhostButton(
                  icon: Icons.auto_awesome_outlined,
                  label: 'ENRICH',
                  onTap: isEnriching ? null : onEnrich,
                  semanticLabel: isEnriching
                      ? 'LLM enrichment in progress'
                      : 'Run LLM enrichment',
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
              if (canHandoff && !reviewed) ...<Widget>[
                ConsoleIconButton(
                  icon: Icons.smart_toy_outlined,
                  onTap: onHandoff,
                  semanticLabel: RecordingCard.handoffLabel,
                  size: 30,
                  iconSize: 17,
                ),
                const SizedBox(width: 7),
              ],
              if (canRoute && !reviewed) ...<Widget>[
                ConsoleIconButton(
                  icon: Icons.outbound_outlined,
                  onTap: onRoute,
                  semanticLabel: RecordingCard.routeLabel,
                  size: 30,
                  iconSize: 17,
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
              _ReviewToggle(
                reviewed: reviewed,
                busy: isMarkingDone,
                onTap: onToggleProcessed,
              ),
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
            Icon(Icons.auto_awesome_outlined, size: 12, color: Console.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                RecordingCard.analyzingLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ConsoleText.micro.copyWith(color: Console.accent),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ScanLine(),
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
    this.semanticLabel,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
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
              Icon(
                icon,
                size: 12,
                color: onTap == null ? Console.dim : Console.text,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: ConsoleText.chip.copyWith(
                  color: onTap == null ? Console.dim : Console.text,
                ),
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
  const _ReviewToggle({
    required this.reviewed,
    required this.busy,
    required this.onTap,
  });

  final bool reviewed;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      checked: reviewed,
      label: busy
          ? 'Moving capture to Done'
          : reviewed
          ? 'Mark as not done'
          : 'Mark as done',
      child: InkResponse(
        onTap: busy
            ? null
            : () {
                if (!reviewed) {
                  HapticFeedback.mediumImpact();
                }
                onTap();
              },
        radius: 22,
        child: DoneBurstAnimation(
          reviewed: reviewed,
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
            child: busy
                ? SizedBox.square(
                    key: const ValueKey<String>('marking-done'),
                    dimension: 19,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Console.green,
                      backgroundColor: Console.green.withValues(alpha: .16),
                    ),
                  )
                : Icon(
                    reviewed
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    key: ValueKey<bool>(reviewed),
                    color: reviewed ? Console.green : Console.dimText,
                    size: 26,
                  ),
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
        color: Console.accent.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Console.accent.withValues(alpha: .22)),
      ),
      child: Text(
        '#$tag',
        style: ConsoleText.micro.copyWith(color: Console.accent),
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

/// Null for the resting state, which draws no badge at all — see the card.
_StatusVisual? _statusVisual(RecordingStatus status) => switch (status) {
  // Persisted but not yet handed to a processor — the design calls it RAW.
  RecordingStatus.saved => _StatusVisual('RAW', Console.muted),
  RecordingStatus.pendingTranscription => _StatusVisual(
    'QUEUED',
    Console.amber,
  ),
  RecordingStatus.transcribing => _StatusVisual(
    'TRANSCRIBING',
    Console.accent,
    pulse: true,
  ),
  RecordingStatus.completed => null,
  RecordingStatus.failed => _StatusVisual('FAILED', Console.red),
};

/// Renders the transcript excerpt on the card, supporting inline expand/collapse
/// and a focus view modal for reading longer captures.
class _CardTranscriptSection extends StatefulWidget {
  const _CardTranscriptSection({
    required this.recording,
    this.projectName,
    required this.onEdit,
  });

  final Recording recording;
  final String? projectName;
  final VoidCallback onEdit;

  @override
  State<_CardTranscriptSection> createState() => _CardTranscriptSectionState();
}

class _CardTranscriptSectionState extends State<_CardTranscriptSection> {
  bool _expanded = false;

  void _openFocusModal() {
    showTranscriptFocusModal(
      context,
      recording: widget.recording,
      projectName: widget.projectName,
      onEdit: widget.onEdit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final String transcript = (widget.recording.transcript ?? '').trim();
    final bool isLong = transcript.length > 120 || transcript.contains('\n');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 11),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topLeft,
                child: Text(
                  transcript,
                  maxLines: _expanded ? null : 3,
                  overflow: _expanded
                      ? TextOverflow.clip
                      : TextOverflow.ellipsis,
                  style: ConsoleText.body,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (isLong) ...<Widget>[
                  ConsoleIconButton(
                    icon: _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    onTap: () => setState(() => _expanded = !_expanded),
                    semanticLabel: _expanded ? 'Collapse text' : 'Expand text',
                    size: 34,
                    iconSize: 18,
                  ),
                  const SizedBox(width: 4),
                  ConsoleIconButton(
                    icon: Icons.open_in_full_rounded,
                    onTap: _openFocusModal,
                    semanticLabel: 'Focus view',
                    size: 34,
                    iconSize: 16,
                  ),
                  const SizedBox(width: 4),
                ],
                CopyButton(
                  text: transcript,
                  tooltip: 'Copy text',
                  semanticLabel: 'Copy text to clipboard',
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
