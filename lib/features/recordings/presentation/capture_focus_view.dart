import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/markdown_view.dart';
import '../../../app/ui_kit.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import 'card_parts.dart';
import 'handoff_sheet.dart';
import 'recording_card.dart';
import 'recordings_controller.dart';

/// Opens the capture in a dedicated reading view.
///
/// This is the queue's detail surface, reached by tapping the capture itself
/// on every form factor — the desktop card's body and the compact row both
/// lead here. On a phone it is the *only* place the item's summary, tags,
/// durability line and actions are drawn, which is why the accordion the row
/// used to open is gone: two ways to reveal the same content on one screen is
/// two things to keep in agreement.
///
/// It reads through [controller] rather than off a snapshot. A capture is a
/// moving object — a transcription lands, enrichment names it, playback starts
/// and stops — and a modal that froze the item at the moment it was opened
/// would show a play button that never becomes a stop button. Resolving by id
/// on every notification also answers the delete case: the item stops existing
/// and the view closes itself rather than acting on a row that is gone.
Future<void> showCaptureFocusView(
  BuildContext context, {
  required RecordingsController controller,
  required String recordingId,
  String? projectName,
  VoidCallback? onEdit,
  double? costUsd,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (BuildContext dialogContext) => _CaptureFocusDialog(
      controller: controller,
      recordingId: recordingId,
      projectName: projectName,
      onEdit: onEdit,
      costUsd: costUsd,
    ),
  );
}

class _CaptureFocusDialog extends StatelessWidget {
  _CaptureFocusDialog({
    required this.controller,
    required this.recordingId,
    required this.projectName,
    required this.onEdit,
    required this.costUsd,
  });

  final RecordingsController controller;
  final String recordingId;
  final String? projectName;
  final VoidCallback? onEdit;
  final double? costUsd;

  Recording? _resolve() {
    for (final Recording item in controller.recordings) {
      if (item.id == recordingId) return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.of(context).size;
    final bool compact = screen.width < Console.compactBreakpoint;
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? _) {
        final Recording? recording = _resolve();
        // Deleted while it was open. Closing is the honest answer: every
        // control below acts on an id the controller would now no-op on, and a
        // view of a capture that no longer exists is a view of nothing.
        if (recording == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.of(context).canPop()) Navigator.of(context).pop();
          });
          return const SizedBox.shrink();
        }
        return Dialog(
          backgroundColor: Console.surface,
          insetPadding: compact
              ? const EdgeInsets.symmetric(horizontal: 10, vertical: 20)
              : const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: Console.borderStrong),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 720,
              maxHeight: screen.height * (compact ? 0.92 : 0.85),
            ),
            child: _FocusBody(
              controller: controller,
              recording: recording,
              projectName: projectName,
              onEdit: onEdit,
              costUsd: costUsd,
              compact: compact,
            ),
          ),
        );
      },
    );
  }
}

class _FocusBody extends StatelessWidget {
  _FocusBody({
    required this.controller,
    required this.recording,
    required this.projectName,
    required this.onEdit,
    required this.costUsd,
    required this.compact,
  });

  final RecordingsController controller;
  final Recording recording;
  final String? projectName;
  final VoidCallback? onEdit;
  final double? costUsd;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final bool failed = recording.status == RecordingStatus.failed;
    final String filename = File(recording.filePath).uri.pathSegments.last;
    final String transcript = (recording.transcript ?? '').trim();
    final String summary = (recording.summary ?? '').trim();
    final int wordCount = transcript.isEmpty
        ? 0
        : transcript
              .split(RegExp(r'\s+'))
              .where((String s) => s.isNotEmpty)
              .length;
    final EdgeInsets pad = compact
        ? const EdgeInsets.fromLTRB(14, 14, 14, 12)
        : const EdgeInsets.all(20);

    return Padding(
      padding: pad,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Header(
            recording: recording,
            filename: filename,
            failed: failed,
            projectName: projectName,
            compact: compact,
          ),
          const SizedBox(height: 14),
          Divider(height: 1, color: Console.border),
          // One selection region over the whole document, so a drag can lift a
          // heading and the paragraph under it in one go. It is also why the
          // renderer below draws `Text.rich` rather than `SelectableText`: a
          // selectable inside a SelectionArea throws.
          Expanded(
            child: SelectionArea(
              child: ListView(
                padding: const EdgeInsets.only(top: 14),
                children: <Widget>[
                  if (summary.isNotEmpty) ...<Widget>[
                    _SectionLabel(
                      label: 'SUMMARY',
                      trailing: CopyButton(
                        text: summary,
                        tooltip: 'Copy summary',
                        semanticLabel: 'Copy summary to clipboard',
                        size: 26,
                        iconSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SimpleMarkdown(
                      text: summary,
                      baseStyle: ConsoleText.cardMeta.copyWith(
                        color: Console.textSoft,
                        height: 1.45,
                      ),
                      accentColor: Console.accent,
                      mutedColor: Console.muted,
                      borderColor: Console.border,
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (recording.tags.isNotEmpty) ...<Widget>[
                    Wrap(
                      spacing: 6,
                      runSpacing: 5,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        for (final String tag in recording.tags)
                          StatusPill(
                            label: '#$tag',
                            color: Console.accent,
                            outlined: true,
                          ),
                        CopyButton(
                          text: tagsClipboardText(recording.tags),
                          tooltip: 'Copy tags',
                          semanticLabel: 'Copy tags to clipboard',
                          size: 24,
                          iconSize: 12,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (recording.error != null) ...<Widget>[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Console.red.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Console.red.withValues(alpha: .35),
                        ),
                      ),
                      child: Text(
                        recording.error!,
                        style: ConsoleText.micro.copyWith(
                          color: Console.redSoft,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  _SectionLabel(
                    label: transcript.isEmpty
                        ? 'NO TEXT YET'
                        : '$wordCount words · ${transcript.length} characters',
                    trailing: transcript.isEmpty
                        ? null
                        : CopyButton(
                            text: transcript,
                            tooltip: 'Copy full text',
                            semanticLabel: 'Copy full text to clipboard',
                          ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Console.surfaceRaised,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Console.border),
                    ),
                    child: transcript.isEmpty
                        ? Text(
                            _emptyTextFor(recording),
                            style: ConsoleText.cardMeta.copyWith(
                              color: Console.muted,
                            ),
                          )
                        : SimpleMarkdown(
                            text: transcript,
                            baseStyle: ConsoleText.body.copyWith(
                              fontSize: 14,
                              height: 1.55,
                              color: Console.text,
                            ),
                            accentColor: Console.accent,
                            mutedColor: Console.muted,
                            borderColor: Console.border,
                          ),
                  ),
                  const SizedBox(height: 14),
                  if (recording.routes.isNotEmpty) ...<Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          Icons.subdirectory_arrow_right_rounded,
                          size: 14,
                          color: Console.green,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            recording.routes.last.target,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: ConsoleText.micro.copyWith(
                              color: Console.green,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  VerificationLine(recording: recording, costUsd: costUsd),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: Console.border),
          const SizedBox(height: 12),
          _Actions(
            controller: controller,
            recording: recording,
            projectName: projectName,
            onEdit: onEdit,
          ),
        ],
      ),
    );
  }
}

/// Says why there is nothing to read, which is never the same reason twice: a
/// queued capture is going to have text, a failed one is not until it is
/// retried, and a raw one has not been offered to a processor at all.
String _emptyTextFor(Recording recording) => switch (recording.status) {
  RecordingStatus.saved => 'Saved and verified. Not handed to a processor yet.',
  RecordingStatus.pendingTranscription => 'Queued for processing.',
  RecordingStatus.transcribing => 'Processing…',
  RecordingStatus.failed =>
    'Processing failed. The source file is intact — retry below.',
  RecordingStatus.completed => 'This capture produced no text.',
};

class _Header extends StatelessWidget {
  _Header({
    required this.recording,
    required this.filename,
    required this.failed,
    required this.projectName,
    required this.compact,
  });

  final Recording recording;
  final String filename;
  final bool failed;
  final String? projectName;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        RecordingLeadingTile(recording: recording, failed: failed),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                displayNameFor(recording),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ConsoleText.cardTitle.copyWith(fontSize: 16),
              ),
              const SizedBox(height: 3),
              Text(
                metaLineFor(recording, filename),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ConsoleText.cardMeta,
              ),
              // Wrapped under the title on a phone rather than beside it: the
              // pills and the close button cannot share 393 px with a name.
              if (projectName != null ||
                  recording.category != null) ...<Widget>[
                const SizedBox(height: 7),
                Wrap(
                  spacing: 6,
                  runSpacing: 5,
                  children: <Widget>[
                    if (projectName != null)
                      StatusPill(
                        label: projectName!,
                        color: Console.mutedSoft,
                        outlined: true,
                      ),
                    if (recording.category != null)
                      StatusPill(
                        label: recording.category!.label,
                        color: categoryColorFor(recording.category),
                        outlined: true,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        ConsoleIconButton(
          icon: Icons.close_rounded,
          onTap: () => Navigator.of(context).pop(),
          semanticLabel: 'Close focus view',
          size: 32,
          iconSize: 18,
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  _SectionLabel({required this.label, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text(label, style: ConsoleText.micro.copyWith(color: Console.dimText)),
        const Spacer(),
        ?trailing,
      ],
    );
  }
}

/// Every action the queue offers on a capture, in one place.
///
/// The compact row used to carry these behind its accordion; they live here
/// now, so the phone and the desktop offer one action surface rather than two
/// that have to be kept in agreement. Each fires straight at the controller —
/// this view adds no capture logic of its own, exactly as the card does not.
class _Actions extends StatelessWidget {
  _Actions({
    required this.controller,
    required this.recording,
    required this.projectName,
    required this.onEdit,
  });

  final RecordingsController controller;
  final Recording recording;
  final String? projectName;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    // Same rule as the card's: a capture with a source and no text has RETRY
    // as its only move, whether the processor lost or never ran.
    final bool canRetry =
        recording.status == RecordingStatus.failed ||
        recording.awaitsProcessing;
    final bool reviewed = recording.isProcessedByUser;
    final bool hasTranscript = (recording.transcript ?? '').trim().isNotEmpty;
    final bool isEnriching = controller.isEnriching(recording.id);
    final bool isPlaying = controller.playingId == recording.id;
    final bool openable = recording.type == CaptureType.video;

    return Row(
      children: <Widget>[
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (canRetry)
                ConsoleIconButton(
                  icon: Icons.refresh_rounded,
                  onTap: () => controller.retryTranscription(recording.id),
                  semanticLabel: 'Retry processing',
                ),
              if (hasTranscript && !isEnriching)
                ConsoleIconButton(
                  icon: Icons.auto_awesome_outlined,
                  onTap: () => controller.retryEnrichment(recording.id),
                  semanticLabel: 'Run LLM enrichment',
                ),
              if (recording.type.isPlayableAudio)
                ConsoleIconButton(
                  icon: isPlaying
                      ? Icons.stop_rounded
                      : Icons.play_arrow_rounded,
                  onTap: () => controller.togglePlayback(recording.id),
                  semanticLabel: isPlaying ? 'Stop playback' : 'Play recording',
                  active: isPlaying,
                )
              else if (openable)
                ConsoleIconButton(
                  icon: Icons.play_arrow_rounded,
                  onTap: () => controller.openSource(recording.id),
                  semanticLabel: RecordingCard.openVideoLabel,
                ),
              if (controller.canHandoff(recording) && !reviewed)
                ConsoleIconButton(
                  icon: Icons.smart_toy_outlined,
                  onTap: () => showHandoffSheet(
                    context,
                    controller: controller,
                    recording: recording,
                    projectName: projectName,
                  ),
                  semanticLabel: RecordingCard.handoffLabel,
                ),
              if (controller.canRoute(recording) && !reviewed)
                ConsoleIconButton(
                  icon: Icons.outbound_outlined,
                  onTap: () => controller.route(recording.id),
                  semanticLabel: RecordingCard.routeLabel,
                ),
              if (onEdit != null)
                ConsoleIconButton(
                  icon: Icons.edit_outlined,
                  // Leaves first: the editor takes over the row underneath this
                  // dialog, and two edit surfaces open on one capture is the state
                  // the queue's single `editingId` exists to prevent.
                  onTap: () {
                    Navigator.of(context).pop();
                    onEdit!();
                  },
                  semanticLabel: 'Edit title and text',
                ),
              ConsoleIconButton(
                icon: reviewed
                    ? Icons.check_circle_rounded
                    : Icons.check_circle_outline_rounded,
                onTap: () => controller.toggleProcessed(recording.id),
                semanticLabel: reviewed ? 'Reopen capture' : 'Mark reviewed',
                active: reviewed,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: Console.muted),
          child: const Text('CLOSE'),
        ),
      ],
    );
  }
}
