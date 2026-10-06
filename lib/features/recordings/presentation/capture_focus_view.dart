import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/markdown_view.dart';
import '../../../app/ui_kit.dart';
import '../../projects/domain/project.dart';
import '../domain/capture_category.dart';
import '../domain/capture_priority.dart';
import '../domain/capture_type.dart';
import '../domain/agent_artifact.dart';
import '../domain/note_vault.dart';
import '../domain/recording.dart';
import 'audio_waveform_visualizer.dart';
import 'agent_artifact_viewer_modal.dart';
import 'card_parts.dart';
import 'handoff_sheet.dart';
import 'inline_edit.dart';
import 'inline_video_player.dart';
import 'recording_card.dart';
import 'recording_editor.dart';
import 'recordings_controller.dart';
import 'tag_editor.dart';

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
  VoidCallback? onConfigureModels,
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
      onConfigureModels: onConfigureModels,
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
    this.onConfigureModels,
    required this.costUsd,
  });

  final RecordingsController controller;
  final String recordingId;
  final String? projectName;
  final VoidCallback? onEdit;
  final VoidCallback? onConfigureModels;
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
              onConfigureModels: onConfigureModels,
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
    this.onConfigureModels,
    required this.costUsd,
    required this.compact,
  });

  final RecordingsController controller;
  final Recording recording;
  final String? projectName;
  final VoidCallback? onEdit;
  final VoidCallback? onConfigureModels;
  final double? costUsd;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final bool failed = recording.status == RecordingStatus.failed;
    final String filename = File(recording.filePath).uri.pathSegments.last;
    final String transcript = (recording.transcript ?? '').trim();
    final String summary = (recording.summary ?? '').trim();
    final AgentArtifact? connections = controller.connectionArtifactFor(recording);
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
            controller: controller,
            recording: recording,
            filename: filename,
            failed: failed,
            projectName: projectName,
            compact: compact,
            elapsed: controller.processingElapsedFor(recording.id),
            isEnriching: controller.isEnriching(recording.id),
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
                  if (recording.type == CaptureType.file &&
                      recording.filePath.isNotEmpty) ...<Widget>[
                    _SectionLabel(
                      label: 'SOURCE FILE',
                      trailing: CopyButton(
                        text: recording.filePath,
                        tooltip: 'Copy file path',
                        semanticLabel: 'Copy file path to clipboard',
                        size: 26,
                        iconSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(recording.title ?? filename),
                    const SizedBox(height: 14),
                  ],
                  if (recording.type == CaptureType.image &&
                      recording.filePath.isNotEmpty) ...<Widget>[
                    _SectionLabel(
                      label: 'SOURCE IMAGE',
                      trailing: CopyButton(
                        text: recording.filePath,
                        tooltip: 'Copy image path',
                        semanticLabel: 'Copy image path to clipboard',
                        size: 26,
                        iconSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _SourceImagePreview(file: File(recording.filePath)),
                    const SizedBox(height: 14),
                  ],
                  if (recording.type == CaptureType.video &&
                      recording.filePath.isNotEmpty) ...<Widget>[
                    _SectionLabel(
                      label: 'VIDEO PLAYBACK',
                      trailing: CopyButton(
                        text: recording.filePath,
                        tooltip: 'Copy video path',
                        semanticLabel: 'Copy video path to clipboard',
                        size: 26,
                        iconSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    InlineVideoPlayer.forRecording(
                      recording: recording,
                      onOpenExternal: () => controller.openSource(recording.id),
                      compact: compact,
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (recording.type.isPlayableAudio &&
                      recording.filePath.isNotEmpty) ...<Widget>[
                    _SectionLabel(
                      label: 'AUDIO PLAYBACK',
                      trailing: CopyButton(
                        text: recording.filePath,
                        tooltip: 'Copy audio path',
                        semanticLabel: 'Copy audio path to clipboard',
                        size: 26,
                        iconSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _AudioPlaybackBar(
                      controller: controller,
                      recording: recording,
                    ),
                    const SizedBox(height: 14),
                  ],
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
                  if (controller.mirrorsToVault && transcript.isNotEmpty) ...<Widget>[
                    _SectionLabel(label: 'CONNECTIONS & NEXT STEP'),
                    const SizedBox(height: 6),
                    if (controller.isAnalyzingConnections(recording.id))
                      const Text('Analyzing related notes…')
                    else if (controller.connectionAnalysisError(recording.id) != null)
                      Text('Analysis failed: ${controller.connectionAnalysisError(recording.id)}')
                    else if (connections != null)
                      Text(connections.snippet ?? 'Analysis saved in your vault.')
                    else
                      const Text('No analysis yet.'),
                    Wrap(children: <Widget>[
                      if (connections != null)
                        TextButton(
                          onPressed: () => showAgentArtifactViewer(
                            context,
                            controller: controller,
                            recording: recording,
                            artifact: connections,
                          ),
                          child: const Text('READ ANALYSIS'),
                        ),
                      TextButton(
                        onPressed: controller.isAnalyzingConnections(recording.id)
                            ? null
                            : () => controller.retryConnectionAnalysis(recording.id),
                        child: const Text('REFRESH CONNECTIONS'),
                      ),
                    ]),
                    const SizedBox(height: 14),
                  ],
                  if (recording.error != null) ...<Widget>[
                    _ErrorBox(
                      error: recording.error!,
                      // Leaves first: the Models tab is behind this dialog.
                      onConfigureModels: onConfigureModels == null
                          ? null
                          : () {
                              Navigator.of(context).pop();
                              onConfigureModels!();
                            },
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
  RecordingStatus.transcribing => recording.type == CaptureType.image
      ? 'Extracting text from image…'
      : 'Transcribing speech to text…',
  RecordingStatus.failed =>
    'Processing failed. The source file is intact — retry below.',
  RecordingStatus.completed => 'This capture produced no text.',
};

/// Why processing failed, with the one fix the app can offer in place when
/// the cause is a missing model.
class _ErrorBox extends StatelessWidget {
  _ErrorBox({required this.error, this.onConfigureModels});

  final String error;
  final VoidCallback? onConfigureModels;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Console.red.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Console.red.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            error,
            style: ConsoleText.micro.copyWith(color: Console.redSoft),
          ),
          if (onConfigureModels != null &&
              error.toLowerCase().contains('not configured')) ...<Widget>[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onConfigureModels,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.tune, size: 15),
              label: const Text(
                'SET UP A MODEL',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  _Header({
    required this.controller,
    required this.recording,
    required this.filename,
    required this.failed,
    required this.projectName,
    required this.compact,
    this.elapsed,
    this.isEnriching = false,
  });

  final RecordingsController controller;
  final Recording recording;
  final String filename;
  final bool failed;
  final String? projectName;
  final bool compact;
  final Duration? elapsed;
  final bool isEnriching;

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
                  recording.category != null ||
                  isEnriching ||
                  recording.status != RecordingStatus.completed ||
                  controller.mirrorsToVault) ...<Widget>[
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
                    if (isEnriching)
                      StatusPill(
                        label: 'ANALYZING',
                        color: Console.accent,
                        pulse: true,
                      )
                    else if (recording.status == RecordingStatus.transcribing)
                      StatusPill(
                        label: elapsed != null
                            ? 'TRANSCRIBING · ${formatDuration(elapsed!)}'
                            : 'TRANSCRIBING',
                        color: Console.accent,
                        pulse: true,
                      )
                    else if (recording.status ==
                        RecordingStatus.pendingTranscription)
                      StatusPill(
                        label: 'QUEUED',
                        color: Console.amber,
                      )
                    else if (failed)
                      StatusPill(
                        label: 'FAILED',
                        color: Console.red,
                      ),
                    if (controller.mirrorsToVault &&
                        (recording.transcript ?? '').trim().isNotEmpty)
                      _VaultSyncBadge(
                        controller: controller,
                        recordingId: recording.id,
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

class _VaultSyncBadge extends StatefulWidget {
  const _VaultSyncBadge({
    required this.controller,
    required this.recordingId,
  });

  final RecordingsController controller;
  final String recordingId;

  @override
  State<_VaultSyncBadge> createState() => _VaultSyncBadgeState();
}

class _VaultSyncBadgeState extends State<_VaultSyncBadge> {
  late Future<bool> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.controller.isCaptureMirrored(widget.recordingId);
  }

  @override
  void didUpdateWidget(covariant _VaultSyncBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _future = widget.controller.isCaptureMirrored(widget.recordingId);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.controller.mirrorsToVault) return const SizedBox.shrink();

    return FutureBuilder<bool>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
        final bool isMirrored = snapshot.data ?? false;
        return StatusPill(
          label: isMirrored ? 'VAULT SYNCED' : 'VAULT PENDING',
          color: isMirrored ? Console.green : Console.mutedSoft,
          outlined: true,
        );
      },
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
    final bool canCancel =
        recording.status == RecordingStatus.transcribing ||
        recording.status == RecordingStatus.pendingTranscription;
    final bool reviewed = recording.isProcessedByUser;
    final bool hasTranscript = (recording.transcript ?? '').trim().isNotEmpty;
    final bool isEnriching = controller.isEnriching(recording.id);
    final bool isPlaying = controller.playingId == recording.id;
    final bool openable = recording.type == CaptureType.video ||
        recording.type == CaptureType.file;

    return Row(
      children: <Widget>[
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (canCancel)
                ConsoleIconButton(
                  icon: Icons.close_rounded,
                  onTap: () => controller.cancelProcessing(recording.id),
                  semanticLabel: 'Cancel processing',
                ),
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
              if (controller.mirrorsToVault && hasTranscript)
                ConsoleIconButton(
                  icon: Icons.folder_shared_outlined,
                  onTap: () async {
                    final VaultOutcome? outcome =
                        await controller.retryVaultMirror(recording.id);
                    if (context.mounted && outcome != null) {
                      final String message = switch (outcome) {
                        VaultOutcome.created => 'Mirrored note to vault',
                        VaultOutcome.updated => 'Updated note in vault',
                        VaultOutcome.unchanged => 'Vault note already up to date',
                        VaultOutcome.foreign =>
                          'Vault note left alone (edited externally)',
                      };
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(message),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  semanticLabel: 'Sync to Obsidian vault',
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
                  icon: recording.type == CaptureType.file
                      ? Icons.open_in_new_rounded
                      : Icons.play_arrow_rounded,
                  onTap: () => controller.openSource(recording.id),
                  semanticLabel: recording.type == CaptureType.file
                      ? RecordingCard.openFileLabel
                      : RecordingCard.openVideoLabel,
                ),
              if ((controller.canHandoff(recording) ||
                      controller.canSend(recording)) &&
                  !reviewed)
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

class _SourceImagePreview extends StatelessWidget {
  const _SourceImagePreview({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        color: Console.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Console.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.file(
        file,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (
          BuildContext context,
          Object error,
          StackTrace? stackTrace,
        ) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  Icons.broken_image_outlined,
                  size: 20,
                  color: Console.muted,
                ),
                const SizedBox(width: 8),
                Text(
                  'Source image not available',
                  style: ConsoleText.cardMeta.copyWith(color: Console.muted),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _AudioPlaybackBar extends StatefulWidget {
  const _AudioPlaybackBar({
    required this.controller,
    required this.recording,
  });

  final RecordingsController controller;
  final Recording recording;

  @override
  State<_AudioPlaybackBar> createState() => _AudioPlaybackBarState();
}

class _AudioPlaybackBarState extends State<_AudioPlaybackBar> {
  static const List<double> _speeds = <double>[1.0, 1.25, 1.5, 2.0];
  late List<double> _samples;

  @override
  void initState() {
    super.initState();
    _samples = generateWaveformSamples(widget.recording.id);
  }

  @override
  void didUpdateWidget(covariant _AudioPlaybackBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recording.id != widget.recording.id) {
      _samples = generateWaveformSamples(widget.recording.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final RecordingsController controller = widget.controller;
    final Recording recording = widget.recording;
    final bool isPlaying = controller.playingId == recording.id;
    final Duration totalDuration = recording.totalDurationMs > 0
        ? Duration(milliseconds: recording.totalDurationMs)
        : (controller.playbackDuration > Duration.zero
            ? controller.playbackDuration
            : Duration.zero);
    final Duration currentPosition =
        isPlaying ? controller.playbackPosition : Duration.zero;

    final double maxSeconds = totalDuration.inMilliseconds > 0
        ? totalDuration.inMilliseconds / 1000.0
        : 1.0;
    final double currentSeconds =
        (currentPosition.inMilliseconds / 1000.0).clamp(0.0, maxSeconds);

    final double currentSpeed = controller.playbackSpeed;

    final double progress = maxSeconds > 0
        ? (currentSeconds / maxSeconds).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Console.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Console.border),
      ),
      child: Row(
        children: <Widget>[
          ConsoleIconButton(
            icon: isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
            onTap: () => controller.togglePlayback(recording.id),
            semanticLabel: isPlaying ? 'Stop playback' : 'Play audio',
            active: isPlaying,
            size: 30,
            iconSize: 18,
          ),
          const SizedBox(width: 8),
          Text(
            '${formatDuration(currentPosition)} / ${formatDuration(totalDuration)}',
            style: ConsoleText.micro.copyWith(color: Console.textSoft),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              slider: true,
              label: 'Audio playback scrub bar',
              value:
                  '${formatDuration(currentPosition)} of ${formatDuration(totalDuration)}',
              increasedValue:
                  '${formatDuration(Duration(milliseconds: ((currentSeconds + 5.0).clamp(0.0, maxSeconds) * 1000).round()))} of ${formatDuration(totalDuration)}',
              decreasedValue:
                  '${formatDuration(Duration(milliseconds: ((currentSeconds - 5.0).clamp(0.0, maxSeconds) * 1000).round()))} of ${formatDuration(totalDuration)}',
              onIncrease: () {
                final double target = (currentSeconds + 5.0).clamp(0.0, maxSeconds);
                controller.seekPlayback(Duration(milliseconds: (target * 1000).round()));
              },
              onDecrease: () {
                final double target = (currentSeconds - 5.0).clamp(0.0, maxSeconds);
                controller.seekPlayback(Duration(milliseconds: (target * 1000).round()));
              },
              child: AudioWaveformVisualizer(
                progress: progress,
                samples: _samples,
                onSeek: (double ratio) {
                  final double targetSec = ratio * maxSeconds;
                  controller.seekPlayback(
                    Duration(milliseconds: (targetSec * 1000).round()),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              final int currentIndex = _speeds.indexOf(currentSpeed);
              final double nextSpeed =
                  _speeds[(currentIndex + 1) % _speeds.length];
              controller.setPlaybackSpeed(nextSpeed);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Console.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Console.border),
              ),
              child: Text(
                '${currentSpeed == 1.0 ? '1' : currentSpeed.toString()}x',
                style: ConsoleText.micro.copyWith(
                  color: currentSpeed > 1.0 ? Console.accent : Console.textSoft,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

}

/// The selected capture, drawn whole beside the master list of the wide Queue.
///
/// The same surface as the focus dialog, laid out for a column that is always
/// on screen: no close control, a labelled action bar instead of a row of
/// icons, the text held to a reading measure, and the file facts in a column
/// of their own when there is width for one. It reads through [controller]
/// for the reason the dialog does — the item keeps moving while it is shown —
/// and adds no capture logic: every control calls the controller entry point
/// the card calls.
class CaptureDetailPanel extends StatelessWidget {
  CaptureDetailPanel({
    super.key,
    required this.controller,
    required this.recording,
    required this.projectName,
    required this.showMetaColumn,
    required this.onEdit,
    required this.onToggleProcessed,
    this.onAppendRecording,
    this.onAppendNote,
    this.onAppendUpload,
    this.isMarkingDone = false,
    this.onConfigureModels,
    this.costUsd,
    this.scrollController,
    this.compact = false,
    this.projects = const <Project>[],
    this.tagSuggestions = const <String>[],
  });

  final RecordingsController controller;
  final Recording recording;
  final String? projectName;

  /// What the project badge offers when clicked. Empty hides the picker.
  final List<Project> projects;

  /// Tags used on other captures, offered by the inline tag editor.
  final List<String> tagSuggestions;

  /// True at [Console.detailMetaBreakpoint] and above: the facts move out of
  /// the reading column into a fixed one beside it.
  final bool showMetaColumn;
  final VoidCallback onEdit;
  final VoidCallback? onAppendRecording;
  final VoidCallback? onAppendNote;
  final ValueChanged<CaptureType>? onAppendUpload;

  /// Routed through the queue rather than straight to the controller, so the
  /// panel's Mark done gets the same saving/done feedback the card's does.
  final VoidCallback onToggleProcessed;
  final bool isMarkingDone;
  final VoidCallback? onConfigureModels;
  final double? costUsd;
  final ScrollController? scrollController;

  /// The phone's full-screen page: tighter gutters and a smaller title, the
  /// same content in the same order.
  final bool compact;

  /// The reading measure: about 72 characters of 15 px text.
  static const double readingWidth = 680;

  @override
  Widget build(BuildContext context) {
    final String transcript = (recording.transcript ?? '').trim();
    final String summary = (recording.summary ?? '').trim();
    final int wordCount = transcript.isEmpty
        ? 0
        : transcript
              .split(RegExp(r'\s+'))
              .where((String s) => s.isNotEmpty)
              .length;

    final Widget article = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: readingWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _PanelBadges(
            controller: controller,
            recording: recording,
            projectName: projectName,
            projects: projects,
          ),
          const SizedBox(height: 14),
          // Every field below is edited where it is read: a click turns it
          // into a field, and leaving the field writes it through the same
          // controller method the editor uses.
          InlineEditText(
            value: recording.title ?? '',
            semanticLabel: 'Edit title',
            hintText: File(recording.filePath).uri.pathSegments.last,
            fontSize: compact ? 20 : 22,
            onCommit: (String value) => controller.setTitle(recording.id, value),
            display: Text(
              displayNameFor(recording),
              style: ConsoleText.cardTitle.copyWith(
                fontSize: compact ? 22 : 26,
                height: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            metaLineFor(
              recording,
              File(recording.filePath).uri.pathSegments.last,
            ),
            style: ConsoleText.cardMeta.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 20),
          if (recording.type.isPlayableAudio &&
              recording.filePath.isNotEmpty) ...<Widget>[
            _AudioPlaybackBar(controller: controller, recording: recording),
            const SizedBox(height: 16),
          ],
          if (recording.type == CaptureType.video &&
              recording.filePath.isNotEmpty) ...<Widget>[
            InlineVideoPlayer.forRecording(
              recording: recording,
              onOpenExternal: () => controller.openSource(recording.id),
            ),
            const SizedBox(height: 16),
          ],
          if (recording.type == CaptureType.image &&
              recording.filePath.isNotEmpty) ...<Widget>[
            _SourceImagePreview(file: File(recording.filePath)),
            const SizedBox(height: 16),
          ],
          _PanelActions(
            controller: controller,
            recording: recording,
            projectName: projectName,
            onEdit: onEdit,
            onAppendRecording: onAppendRecording,
            onAppendNote: onAppendNote,
            onAppendUpload: onAppendUpload,
            onToggleProcessed: onToggleProcessed,
            isMarkingDone: isMarkingDone,
          ),
          const SizedBox(height: 24),
          if (recording.error != null) ...<Widget>[
            _ErrorBox(
              error: recording.error!,
              onConfigureModels: onConfigureModels,
            ),
            const SizedBox(height: 22),
          ],
          if (controller.isEnriching(recording.id)) ...<Widget>[
            ProcessingStrip(enriching: true, type: recording.type),
            const SizedBox(height: 22),
          ] else if (recording.status ==
              RecordingStatus.transcribing) ...<Widget>[
            ProcessingStrip(
              enriching: false,
              type: recording.type,
              elapsed: controller.processingElapsedFor(recording.id),
            ),
            const SizedBox(height: 22),
          ],
          _PanelSectionLabel(label: 'Summary'),
          const SizedBox(height: 8),
          InlineEditText(
            value: summary,
            semanticLabel: 'Edit summary',
            hintText: 'Summary / paraphrase',
            multiline: true,
            fontSize: 16,
            onCommit: (String value) =>
                controller.setSummary(recording.id, value),
            display: summary.isEmpty
                ? Text(
                    'Add a summary',
                    style: ConsoleText.body.copyWith(
                      fontSize: 15,
                      color: Console.muted,
                    ),
                  )
                : SimpleMarkdown(
                    text: summary,
                    baseStyle: ConsoleText.body.copyWith(
                      fontSize: 16,
                      height: 1.6,
                      color: Console.text,
                    ),
                    accentColor: Console.accent,
                    mutedColor: Console.muted,
                    borderColor: Console.border,
                  ),
          ),
          const SizedBox(height: 24),
          _PanelSectionLabel(
            label: transcript.isEmpty
                ? 'Transcript'
                : 'Transcript · $wordCount words',
          ),
          const SizedBox(height: 8),
          InlineEditText(
            value: transcript,
            semanticLabel: 'Edit transcript',
            hintText: 'Transcript / OCR text / note',
            multiline: true,
            allowEmpty: false,
            onCommit: (String value) =>
                controller.editTranscript(recording.id, value),
            display: transcript.isEmpty
                ? Text(
                    _emptyTextFor(recording),
                    style: ConsoleText.body.copyWith(
                      fontSize: 15,
                      color: Console.muted,
                    ),
                  )
                : SimpleMarkdown(
                    text: transcript,
                    baseStyle: ConsoleText.body.copyWith(
                      fontSize: 15,
                      height: 1.65,
                      color: Console.textSoft,
                    ),
                    accentColor: Console.accent,
                    mutedColor: Console.muted,
                    borderColor: Console.border,
                  ),
          ),
          const SizedBox(height: 24),
          InlineEditTags(
            editor: TagEditor(
              tags: recording.tags,
              suggestions: tagSuggestions,
              onChanged: (List<String> values) =>
                  controller.setTags(recording.id, values),
            ),
            display: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final String tag in recording.tags)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Console.surfaceRaised,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '#$tag',
                      style: ConsoleText.body.copyWith(
                        fontSize: 12,
                        color: Console.muted,
                      ),
                    ),
                  ),
                if (recording.tags.isEmpty)
                  Text(
                    'Add tags',
                    style: ConsoleText.body.copyWith(
                      fontSize: 13,
                      color: Console.muted,
                    ),
                  )
                else
                  CopyButton(
                    text: tagsClipboardText(recording.tags),
                    tooltip: 'Copy tags',
                    semanticLabel: 'Copy tags to clipboard',
                    size: 26,
                    iconSize: 13,
                  ),
              ],
            ),
          ),
          if (recording.routes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 18),
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
                    style: ConsoleText.micro.copyWith(color: Console.green),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    final Widget meta = _PanelMeta(
      controller: controller,
      recording: recording,
      costUsd: costUsd,
      showKeys: !compact,
    );

    return SelectionArea(
      child: ListView(
        controller: scrollController,
        padding: compact
            ? const EdgeInsets.fromLTRB(16, 16, 16, 32)
            : const EdgeInsets.fromLTRB(48, 36, 48, 48),
        children: <Widget>[
          if (showMetaColumn)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Align(alignment: Alignment.topLeft, child: article),
                ),
                const SizedBox(width: 48),
                SizedBox(width: Console.detailMetaWidth, child: meta),
              ],
            )
          else ...<Widget>[
            article,
            const SizedBox(height: 32),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: readingWidth),
              child: meta,
            ),
          ],
        ],
      ),
    );
  }
}

class _PanelSectionLabel extends StatelessWidget {
  _PanelSectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: ConsoleText.micro.copyWith(
        fontSize: 11,
        letterSpacing: 1.3,
        color: Console.muted,
      ),
    );
  }
}

/// Category first — it is the one coloured label, and the only place besides
/// the list's dot that the category colour is spent — then the project, then
/// whatever the pipeline is doing.
class _PanelBadges extends StatelessWidget {
  _PanelBadges({
    required this.controller,
    required this.recording,
    required this.projectName,
    required this.projects,
  });

  final RecordingsController controller;
  final Recording recording;
  final String? projectName;
  final List<Project> projects;

  /// Menu value for "none": a null item would read as a dismissed menu.
  static const String _none = '';

  @override
  Widget build(BuildContext context) {
    final bool enriching = controller.isEnriching(recording.id);
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        _BadgeMenu(
          tooltip: 'Set category',
          selected: recording.category?.name ?? _none,
          options: <(String, String)>[
            (_none, '—'),
            for (final CaptureCategory value in CaptureCategory.values)
              (value.name, value.label),
          ],
          onSelected: (String name) => controller.setCategory(
            recording.id,
            name == _none ? null : CaptureCategory.fromName(name),
          ),
          child: recording.category != null
              ? StatusPill(
                  label: recording.category!.label,
                  color: categoryColorFor(recording.category),
                  outlined: true,
                )
              : StatusPill(
                  label: '+ CATEGORY',
                  color: Console.muted,
                  outlined: true,
                ),
        ),
        _BadgeMenu(
          tooltip: recording.priorityReason ?? 'Set priority',
          selected: recording.priority?.name ?? _none,
          options: <(String, String)>[
            (_none, '—'),
            for (final CapturePriority value in CapturePriority.values)
              (value.name, value.label),
          ],
          onSelected: (String name) => controller.setPriority(
            recording.id,
            CapturePriority.tryName(name),
          ),
          child: recording.priority != null
              ? StatusPill(
                  label: recording.priority!.label,
                  color: priorityColorFor(recording.priority!),
                  outlined: true,
                )
              : StatusPill(
                  label: '+ PRIORITY',
                  color: Console.muted,
                  outlined: true,
                ),
        ),
        if (enriching)
          StatusPill(label: 'ANALYZING', color: Console.accent, pulse: true)
        else
          switch (recording.status) {
            RecordingStatus.saved => StatusPill(
              label: 'RAW',
              color: Console.muted,
            ),
            RecordingStatus.pendingTranscription => StatusPill(
              label: 'QUEUED',
              color: Console.amber,
            ),
            RecordingStatus.transcribing => StatusPill(
              label: recording.type == CaptureType.image
                  ? 'EXTRACTING'
                  : 'TRANSCRIBING',
              color: Console.accent,
              pulse: true,
            ),
            RecordingStatus.failed => StatusPill(
              label: 'FAILED',
              color: Console.red,
            ),
            RecordingStatus.completed => const SizedBox.shrink(),
          },
        if (projects.isNotEmpty)
          _BadgeMenu(
            tooltip: 'Set project',
            selected: recording.projectId ?? _none,
            options: <(String, String)>[
              (_none, '—'),
              for (final Project project in projects)
                (project.id, project.name),
            ],
            onSelected: (String id) =>
                controller.setProject(recording.id, id == _none ? null : id),
            child: Text(
              projectName ?? '+ project',
              style: ConsoleText.body.copyWith(
                fontSize: 13,
                color: Console.muted,
              ),
            ),
          )
        else if (projectName != null)
          Text(
            projectName!,
            style: ConsoleText.body.copyWith(
              fontSize: 13,
              color: Console.muted,
            ),
          ),
      ],
    );
  }
}

/// A badge that opens a pick-one menu. The choice writes on the tap, like a
/// chip in the editor.
class _BadgeMenu extends StatelessWidget {
  _BadgeMenu({
    required this.tooltip,
    required this.selected,
    required this.options,
    required this.onSelected,
    required this.child,
  });

  final String tooltip;
  final String selected;

  /// `(value, label)` pairs, in display order.
  final List<(String, String)> options;
  final ValueChanged<String> onSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: tooltip,
      initialValue: selected,
      color: Console.surface,
      onSelected: (String value) {
        if (value != selected) onSelected(value);
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        for (final (String value, String label) in options)
          PopupMenuItem<String>(
            value: value,
            height: 36,
            child: Text(
              label,
              style: ConsoleText.body.copyWith(
                fontSize: 13,
                color: value == selected ? Console.accent : Console.text,
              ),
            ),
          ),
      ],
      child: MouseRegion(cursor: SystemMouseCursors.click, child: child),
    );
  }
}

/// Every action the card offers, spelled out. Enrich leads because it is the
/// one that changes what the list shows; Mark done sits apart at the end
/// because it is the one that takes the capture off the desk.
class _PanelActions extends StatelessWidget {
  _PanelActions({
    required this.controller,
    required this.recording,
    required this.projectName,
    required this.onEdit,
    this.onAppendRecording,
    this.onAppendNote,
    this.onAppendUpload,
    required this.onToggleProcessed,
    required this.isMarkingDone,
  });

  final RecordingsController controller;
  final Recording recording;
  final String? projectName;
  final VoidCallback onEdit;
  final VoidCallback? onAppendRecording;
  final VoidCallback? onAppendNote;
  final ValueChanged<CaptureType>? onAppendUpload;
  final VoidCallback onToggleProcessed;
  final bool isMarkingDone;

  @override
  Widget build(BuildContext context) {
    final bool canRetry =
        recording.status == RecordingStatus.failed ||
        recording.awaitsProcessing;
    final bool canCancel =
        recording.status == RecordingStatus.transcribing ||
        recording.status == RecordingStatus.pendingTranscription;
    final bool reviewed = recording.isProcessedByUser;
    final String transcript = (recording.transcript ?? '').trim();
    final bool hasTranscript = transcript.isNotEmpty;
    final bool isEnriching = controller.isEnriching(recording.id);
    final bool isPlaying = controller.playingId == recording.id;

    final List<Widget> leading = <Widget>[
      if (canCancel)
        _PanelButton(
          icon: Icons.close_rounded,
          label: 'Cancel',
          onPressed: () => controller.cancelProcessing(recording.id),
        ),
      if (canRetry)
        _PanelButton(
          icon: Icons.refresh_rounded,
          label: 'Retry',
          primary: true,
          onPressed: () => controller.retryTranscription(recording.id),
        ),
      if (hasTranscript)
        _PanelButton(
          icon: Icons.auto_awesome_outlined,
          label: 'Enrich',
          primary: !canRetry,
          semanticLabel: 'Run LLM enrichment',
          onPressed: isEnriching
              ? null
              : () => controller.retryEnrichment(recording.id),
        ),
      if (recording.type.isPlayableAudio)
        _PanelButton(
          icon: isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
          label: isPlaying ? 'Stop' : 'Play',
          semanticLabel: isPlaying ? 'Stop playback' : 'Play recording',
          onPressed: () => controller.togglePlayback(recording.id),
        )
      else if (recording.type == CaptureType.video ||
          recording.type == CaptureType.file)
        _PanelButton(
          icon: Icons.open_in_new_rounded,
          label: 'Open',
          semanticLabel: recording.type == CaptureType.file
              ? RecordingCard.openFileLabel
              : RecordingCard.openVideoLabel,
          onPressed: () => controller.openSource(recording.id),
        ),
      if ((controller.canHandoff(recording) ||
              controller.canSend(recording)) &&
          !reviewed)
        _PanelButton(
          icon: Icons.smart_toy_outlined,
          label: 'Send',
          semanticLabel: RecordingCard.handoffLabel,
          onPressed: () => showHandoffSheet(
            context,
            controller: controller,
            recording: recording,
            projectName: projectName,
          ),
        ),
      if (controller.canRoute(recording) && !reviewed)
        _PanelButton(
          icon: Icons.outbound_outlined,
          label: 'Route',
          semanticLabel: RecordingCard.routeLabel,
          onPressed: () => controller.route(recording.id),
        ),
      if (controller.mirrorsToVault && hasTranscript)
        _PanelButton(
          icon: Icons.folder_shared_outlined,
          label: 'Vault',
          semanticLabel: 'Sync to Obsidian vault',
          onPressed: () => controller.retryVaultMirror(recording.id),
        ),
      if (onAppendRecording != null ||
          onAppendNote != null ||
          onAppendUpload != null)
        _PanelButton(
          icon: Icons.add_rounded,
          label: '+ Fragment',
          onPressed: () => showAppendFragmentMenu(
            context,
            onAppendRecording: onAppendRecording,
            onAppendNote: onAppendNote,
            onAppendUpload: onAppendUpload,
          ),
        ),
      _PanelButton(
        icon: Icons.edit_outlined,
        label: 'Edit',
        semanticLabel: 'Edit title and text',
        onPressed: onEdit,
      ),
      if (hasTranscript) _PanelCopyButton(text: transcript),
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: Wrap(spacing: 6, runSpacing: 6, children: leading)),
        const SizedBox(width: 12),
        _PanelButton(
          icon: reviewed
              ? Icons.check_circle_rounded
              : Icons.check_circle_outline_rounded,
          label: reviewed ? 'Reopen' : 'Mark done',
          semanticLabel: reviewed ? 'Reopen capture' : 'Mark reviewed',
          outlined: true,
          onPressed: isMarkingDone ? null : onToggleProcessed,
        ),
      ],
    );
  }
}

class _PanelButton extends StatelessWidget {
  _PanelButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.semanticLabel,
    this.primary = false,
    this.outlined = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final String? semanticLabel;
  final bool primary;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final Color foreground = primary ? Console.ink : Console.text;
    final ButtonStyle style = TextButton.styleFrom(
      foregroundColor: foreground,
      backgroundColor: primary ? Console.accent : Colors.transparent,
      disabledForegroundColor: Console.muted,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: const Size(0, 34),
      textStyle: ConsoleText.body.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: outlined || !primary
            ? BorderSide(color: Console.border)
            : BorderSide.none,
      ),
    );
    final Widget button = TextButton.icon(
      onPressed: onPressed,
      style: style,
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
    if (semanticLabel == null) return button;
    return Semantics(
      label: semanticLabel,
      button: true,
      excludeSemantics: true,
      enabled: onPressed != null,
      onTap: onPressed,
      child: button,
    );
  }
}

/// Copy with a label that answers. The app uses no snackbars, so the button
/// itself says `Copied` for a moment, the way [CopyButton] morphs its icon.
class _PanelCopyButton extends StatefulWidget {
  const _PanelCopyButton({required this.text});

  final String text;

  @override
  State<_PanelCopyButton> createState() => _PanelCopyButtonState();
}

class _PanelCopyButtonState extends State<_PanelCopyButton> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _PanelButton(
      icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
      label: _copied ? 'Copied' : 'Copy',
      semanticLabel: 'Copy full text to clipboard',
      onPressed: _copy,
    );
  }
}

/// The facts the card used to print in its footer, one per line.
class _PanelMeta extends StatelessWidget {
  _PanelMeta({
    required this.controller,
    required this.recording,
    required this.costUsd,
    required this.showKeys,
  });

  final RecordingsController controller;
  final Recording recording;
  final double? costUsd;

  /// The shortcut legend, which means nothing on a phone.
  final bool showKeys;

  @override
  Widget build(BuildContext context) {
    final List<(String, Widget)> rows = <(String, Widget)>[
      ('File', _value('verified')),
      ('Size', _value(formatBytes(recording.totalSizeBytes) ?? '—')),
      ('Cost', _value(costUsd == null ? '—' : formatUsd(costUsd!))),
      ('Saved', _value(formatDateTime(recording.createdAt))),
      ('Index', _value('persisted')),
      ('Status', _value(_statusLabel())),
      if (recording.segments.isNotEmpty)
        ('Segments', _value('${recording.segments.length}')),
      if (controller.mirrorsToVault &&
          (recording.transcript ?? '').trim().isNotEmpty)
        (
          'Vault',
          _VaultSyncBadge(controller: controller, recordingId: recording.id),
        ),
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Console.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final (String key, Widget value) in rows)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Console.border)),
              ),
              child: Row(
                children: <Widget>[
                  Text(
                    key,
                    style: ConsoleText.body.copyWith(
                      fontSize: 13,
                      color: Console.muted,
                    ),
                  ),
                  const Spacer(),
                  value,
                ],
              ),
            ),
          if (showKeys) ...<Widget>[
          const SizedBox(height: 16),
          Text(
            '↑ / ↓  move · enter  open\n'
            'Ctrl+F  search',
            style: ConsoleText.micro.copyWith(
              height: 1.7,
              color: Console.muted,
            ),
          ),
          ],
        ],
      ),
    );
  }

  Widget _value(String text) => Text(
    text,
    style: ConsoleText.cardMeta.copyWith(fontSize: 13, color: Console.text),
  );

  String _statusLabel() {
    if (controller.isEnriching(recording.id)) return 'analyzing';
    return switch (recording.status) {
      RecordingStatus.saved => 'raw',
      RecordingStatus.pendingTranscription => 'queued',
      RecordingStatus.transcribing => 'transcribing',
      RecordingStatus.failed => 'failed',
      RecordingStatus.completed =>
        recording.category == null ? 'ready' : 'enriched',
    };
  }
}
