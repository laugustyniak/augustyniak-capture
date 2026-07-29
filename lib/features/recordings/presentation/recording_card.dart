import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';

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
    required this.onTogglePlay,
    required this.onRetry,
    required this.onEdit,
    required this.onToggleProcessed,
  });

  final Recording recording;
  final bool isPlaying;
  final VoidCallback onTogglePlay;
  final VoidCallback onRetry;
  final VoidCallback onEdit;
  final VoidCallback onToggleProcessed;

  @override
  Widget build(BuildContext context) {
    final bool failed = recording.status == RecordingStatus.failed;
    final bool reviewed = recording.isProcessedByUser;
    final _StatusVisual visual = _statusVisual(recording.status);
    final String filename = File(recording.filePath).uri.pathSegments.last;
    final String? title = recording.title?.trim();
    final bool hasTitle = title != null && title.isNotEmpty;
    final String displayName = hasTitle ? title : filename;
    // Generic processor output: a transcription, OCR text or a note body.
    final String transcript = recording.transcript ?? '';
    final bool hasTranscript = transcript.trim().isNotEmpty;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: Console.surface,
        borderRadius: BorderRadius.circular(12),
        // The border is the one place status colours the whole item: a failure
        // and a reviewed item both have to be findable while scrolling.
        border: Border.all(
          color: failed
              ? Console.red.withValues(alpha: .35)
              : reviewed
                  ? Console.cyan.withValues(alpha: .35)
                  : Console.border,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                ConsoleIconTile(
                  animate: true,
                  icon: _typeIcon(recording.type),
                  color: failed ? Console.red : Console.cyan,
                  background: failed
                      ? Console.red.withValues(alpha: .1)
                      : Console.iconTile,
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
                        _metaLine(recording, filename),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ConsoleText.cardMeta,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                StatusPill(
                  label: visual.label,
                  color: visual.color,
                  pulse: visual.pulse,
                ),
              ],
            ),
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
                Expanded(child: _VerificationLine(recording: recording)),
                const SizedBox(width: 8),
                if (failed) ...<Widget>[
                  _GhostButton(
                    icon: Icons.refresh_rounded,
                    label: 'RETRY',
                    onTap: onRetry,
                  ),
                  const SizedBox(width: 8),
                ],
                // Playback is audio-only; text/image/video items have no track.
                if (recording.type.isPlayableAudio) ...<Widget>[
                  ConsoleIconButton(
                    icon: isPlaying
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded,
                    onTap: onTogglePlay,
                    semanticLabel:
                        isPlaying ? 'Stop playback' : 'Play recording',
                    active: isPlaying,
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
      ),
    );
  }
}

/// `✓ file verified · 6.8 MB · persisted` — the durability guarantee, stated on
/// every card. The size segment disappears on legacy rows, which never recorded
/// one, rather than printing a made-up `0 B`.
class _VerificationLine extends StatelessWidget {
  const _VerificationLine({required this.recording});

  final Recording recording;

  @override
  Widget build(BuildContext context) {
    final String? size = formatBytes(recording.sizeBytes);
    final String text = <String>[
      'file verified',
      if (size != null) size,
      'persisted',
    ].join(' · ');

    return Row(
      children: <Widget>[
        const Icon(Icons.check_rounded, size: 12, color: Console.green),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ConsoleText.micro,
          ),
        ),
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

/// The review flag. Deliberately the last control on the row and the only one
/// that is never gated on status: reviewing is a user-owned axis, independent
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
      label: reviewed ? 'Mark as not reviewed' : 'Mark as reviewed',
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
            color: reviewed ? Console.green : Console.dim,
            size: 26,
          ),
        ),
      ),
    );
  }
}

/// `10:24 · m4a · 2026-07-27 12:00` — duration only when the type has one, so
/// an image or a note never claims `00:00`.
String _metaLine(Recording recording, String filename) {
  final String extension = filename.contains('.')
      ? filename.split('.').last.toLowerCase()
      : recording.type.name;
  return <String>[
    if (recording.type.hasDuration && recording.durationMs > 0)
      formatDuration(Duration(milliseconds: recording.durationMs)),
    extension,
    formatDateTime(recording.createdAt),
  ].join(' · ');
}

IconData _typeIcon(CaptureType type) => switch (type) {
      CaptureType.audioRecording => Icons.mic_none_rounded,
      CaptureType.audioUpload => Icons.audio_file_outlined,
      CaptureType.image => Icons.image_outlined,
      CaptureType.text => Icons.description_outlined,
      CaptureType.video => Icons.movie_outlined,
    };

class _StatusVisual {
  const _StatusVisual(this.label, this.color, {this.pulse = false});
  final String label;
  final Color color;
  final bool pulse;
}

_StatusVisual _statusVisual(RecordingStatus status) => switch (status) {
      // Persisted but not yet handed to a processor — the design calls it RAW.
      RecordingStatus.saved => const _StatusVisual('RAW', Console.muted),
      RecordingStatus.pendingTranscription =>
        const _StatusVisual('QUEUED', Console.amber),
      RecordingStatus.transcribing =>
        const _StatusVisual('TRANSCRIBING', Console.cyan, pulse: true),
      RecordingStatus.completed => const _StatusVisual('READY', Console.green),
      RecordingStatus.failed => const _StatusVisual('FAILED', Console.red),
    };
