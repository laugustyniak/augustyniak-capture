import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';

/// One queue item. Split out of `queue_tab.dart`, which had grown to four
/// responsibilities; the card is the largest and the one that varies per
/// [CaptureType].
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
    final bool canRetry = recording.status == RecordingStatus.failed;
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
        color: reviewed ? const Color(0xFF102C31) : Console.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: reviewed ? const Color(0xFF2F8B68) : Console.border,
          width: reviewed ? 1.4 : 1,
        ),
        boxShadow: reviewed
            ? const <BoxShadow>[
                BoxShadow(
                  color: Color(0x2231D58D),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ]
            : const <BoxShadow>[],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ConsoleIconTile(
                  animate: true,
                  icon: reviewed
                      ? Icons.done_all_rounded
                      : _typeIcon(recording.type),
                  color: reviewed ? Console.green : Console.cyan,
                  background:
                      reviewed ? const Color(0xFF194E40) : Console.iconTile,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        <String>[
                          if (hasTitle) filename,
                          if (recording.durationMs > 0)
                            '${formatDateTime(recording.createdAt)} · '
                                '${formatDuration(Duration(milliseconds: recording.durationMs))}'
                          else
                            formatDateTime(recording.createdAt),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Console.mutedSoft,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
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
                  ),
                  const SizedBox(width: 8),
                ],
                ConsoleIconButton(
                  icon: Icons.edit_outlined,
                  onTap: onEdit,
                  semanticLabel: 'Edit title and text',
                  iconSize: 20,
                ),
                const SizedBox(width: 8),
                Semantics(
                  button: true,
                  checked: reviewed,
                  label: reviewed
                      ? 'Mark note as not reviewed'
                      : 'Mark note as reviewed',
                  child: InkResponse(
                    onTap: onToggleProcessed,
                    radius: 25,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 320),
                      transitionBuilder:
                          (Widget child, Animation<double> animation) {
                        return ScaleTransition(
                          scale: CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutBack,
                          ),
                          child:
                              FadeTransition(opacity: animation, child: child),
                        );
                      },
                      child: Icon(
                        reviewed
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        key: ValueKey<bool>(reviewed),
                        color: reviewed ? Console.green : Console.muted,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: <Widget>[
                StatusPill(label: visual.label, color: visual.color),
                const StatusPill(
                  label: 'LOCAL FILE VERIFIED',
                  color: Console.green,
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: reviewed
                      ? const StatusPill(
                          key: ValueKey<String>('reviewed'),
                          label: 'REVIEWED BY YOU',
                          color: Console.green,
                        )
                      : const StatusPill(
                          key: ValueKey<String>('unreviewed'),
                          label: 'NEEDS REVIEW',
                          color: Console.amber,
                        ),
                ),
              ],
            ),
            if (recording.status == RecordingStatus.transcribing) ...<Widget>[
              const SizedBox(height: 12),
              const LinearProgressIndicator(
                minHeight: 4,
                color: Console.cyan,
                backgroundColor: Color(0xFF1A3A51),
              ),
            ],
            if (hasTranscript) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      transcript,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Console.textSoft,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Copies the whole text, not the four lines rendered above.
                  CopyButton(
                    text: transcript,
                    tooltip: 'Copy transcript',
                    semanticLabel: 'Copy transcript to clipboard',
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
                style: const TextStyle(color: Console.redSoft, fontSize: 10),
              ),
            ],
            if (canRetry) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 17),
                  label: const Text('RETRY TRANSCRIPTION'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

IconData _typeIcon(CaptureType type) => switch (type) {
      CaptureType.audioRecording => Icons.graphic_eq,
      CaptureType.audioUpload => Icons.audio_file_outlined,
      CaptureType.image => Icons.image_outlined,
      CaptureType.text => Icons.sticky_note_2_outlined,
      CaptureType.video => Icons.movie_outlined,
    };

class _StatusVisual {
  const _StatusVisual(this.label, this.color);
  final String label;
  final Color color;
}

_StatusVisual _statusVisual(RecordingStatus status) => switch (status) {
      RecordingStatus.saved =>
        const _StatusVisual('SAVED · WAITING', Console.amber),
      RecordingStatus.pendingTranscription =>
        const _StatusVisual('QUEUED', Console.amber),
      RecordingStatus.transcribing =>
        const _StatusVisual('WHISPER RUNNING', Console.cyan),
      RecordingStatus.completed =>
        const _StatusVisual('TRANSCRIPT READY', Console.green),
      RecordingStatus.failed =>
        const _StatusVisual('TRANSCRIPTION FAILED', Console.red),
    };
