import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import 'recordings_controller.dart';

enum RecordingFilter { queue, ready, failed, raw }

/// The original Phase-1 screen: search, status filters, metrics and the
/// recording list. Owns only view state; every mutation goes through
/// [RecordingsController].
class QueueTab extends StatefulWidget {
  const QueueTab({super.key, required this.controller});

  final RecordingsController controller;

  @override
  State<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<QueueTab> {
  RecordingFilter selectedFilter = RecordingFilter.queue;
  String searchQuery = '';
  final TextEditingController searchController = TextEditingController();

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final RecordingsController controller = widget.controller;
    final List<Recording> visible = _filter(controller.recordings);
    // The controller derives this from the same statuses; keeping a second
    // copy here is how the two drift apart.
    final int processingCount = controller.pendingProcessingCount;
    final int failedCount = controller.recordings
        .where((Recording item) => item.status == RecordingStatus.failed)
        .length;
    final int reviewedCount = controller.recordings
        .where((Recording item) => item.isProcessedByUser)
        .length;

    return SafeArea(
      child: Column(
        children: <Widget>[
          if (controller.error != null) ErrorBanner(message: controller.error!),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 110),
              children: <Widget>[
                _SearchField(
                  controller: searchController,
                  value: searchQuery,
                  onChanged: (String value) {
                    setState(() => searchQuery = value);
                  },
                ),
                const SizedBox(height: 14),
                _FilterRow(
                  selected: selectedFilter,
                  onSelected: (RecordingFilter value) {
                    setState(() => selectedFilter = value);
                  },
                ),
                const SizedBox(height: 16),
                _MetricsRow(
                  total: controller.recordings.length,
                  reviewed: reviewedCount,
                  running: processingCount,
                  failed: failedCount,
                ),
                const SizedBox(height: 20),
                SectionHeader(
                  title: _sectionTitle(selectedFilter),
                  trailing: '${visible.length} ITEMS',
                ),
                const SizedBox(height: 12),
                if (visible.isEmpty)
                  EmptyPanel(
                    icon: Icons.graphic_eq,
                    title: _emptyLabel(selectedFilter),
                    blurb:
                        'Audio is always persisted and verified before transcription starts.',
                  )
                else
                  ...visible.map(
                    (Recording recording) => Padding(
                      padding: const EdgeInsets.only(bottom: 11),
                      child: _RecordingCard(
                        recording: recording,
                        isPlaying: controller.playingId == recording.id,
                        onTogglePlay: () =>
                            controller.togglePlayback(recording.id),
                        onRetry: () =>
                            controller.retryTranscription(recording.id),
                        onEdit: () => _openEditSheet(context, recording),
                        onToggleProcessed: () async {
                          await HapticFeedback.selectionClick();
                          await controller.toggleProcessed(recording.id);
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Recording> _filter(List<Recording> recordings) {
    final List<Recording> byStatus = switch (selectedFilter) {
      RecordingFilter.queue => recordings
          .where((Recording item) =>
              item.status == RecordingStatus.pendingTranscription ||
              item.status == RecordingStatus.transcribing ||
              item.status == RecordingStatus.saved)
          .toList(),
      RecordingFilter.ready => recordings
          .where((Recording item) => item.status == RecordingStatus.completed)
          .toList(),
      RecordingFilter.failed => recordings
          .where((Recording item) => item.status == RecordingStatus.failed)
          .toList(),
      RecordingFilter.raw => recordings,
    };
    final String query = searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return byStatus;
    }
    return byStatus.where((Recording item) {
      final String haystack = <String?>[
        item.transcript,
        item.title,
        item.filePath.split(Platform.pathSeparator).last,
        item.id,
      ].whereType<String>().join(' ').toLowerCase();
      return haystack.contains(query);
    }).toList();
  }

  /// Inline editor for an item's title and processor-output text. Uses a bottom
  /// sheet (like the note composer) — the app has no dialogs/snackbars.
  Future<void> _openEditSheet(BuildContext context, Recording recording) async {
    final _EditResult? result = await showModalBottomSheet<_EditResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Console.background,
      builder: (BuildContext _) => _EditSheet(recording: recording),
    );
    if (result == null) return; // cancelled
    await widget.controller.setTitle(recording.id, result.title);
    await widget.controller.editTranscript(recording.id, result.transcript);
  }
}

class _EditResult {
  const _EditResult({required this.title, required this.transcript});
  final String title;
  final String transcript;
}

/// Two-field editor: title (optional) and the processor-output text. Prefilled
/// from the item; returns the trimmed values on Save, null on cancel.
class _EditSheet extends StatefulWidget {
  const _EditSheet({required this.recording});

  final Recording recording;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final TextEditingController _title =
      TextEditingController(text: widget.recording.title ?? '');
  late final TextEditingController _text =
      TextEditingController(text: widget.recording.transcript ?? '');

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 18,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionHeader(title: 'EDYTUJ'),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            textInputAction: TextInputAction.next,
            style: const TextStyle(color: Console.text, fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Tytuł (opcjonalny)',
              hintText: 'np. Spotkanie z klientem',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            maxLines: 6,
            minLines: 3,
            style: const TextStyle(color: Console.text, fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Tekst',
              hintText: 'Transkrypcja / tekst OCR / notatka',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('ANULUJ'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(
                  _EditResult(
                    title: _title.text,
                    transcript: _text.text,
                  ),
                ),
                child: const Text('ZAPISZ'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Capture FAB. Lives in the page shell but only ever appears on the Queue tab.
class RecordButton extends StatelessWidget {
  const RecordButton({super.key, required this.controller});

  final RecordingsController controller;

  @override
  Widget build(BuildContext context) {
    final bool recording = controller.isRecording;
    return FloatingActionButton.extended(
      heroTag: 'record',
      backgroundColor: recording ? Console.red : Console.cyan,
      foregroundColor: Console.ink,
      onPressed: controller.isBusy
          ? null
          : recording
              ? controller.stopRecording
              : controller.startRecording,
      icon: Icon(recording ? Icons.stop_rounded : Icons.mic_rounded),
      label: Text(
        recording
            ? 'SAVE ${formatDuration(controller.elapsed)}'
            : controller.isBusy
                ? 'PROCESSING'
                : 'CAPTURE',
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.value,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(color: Console.text, fontSize: 13),
      decoration: InputDecoration(
        hintText: 'Search recordings and transcripts',
        hintStyle: const TextStyle(color: Console.muted, fontSize: 13),
        prefixIcon: const Icon(Icons.search, color: Console.muted),
        suffixIcon: value.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, color: Console.muted),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        filled: true,
        fillColor: Console.surfaceDeep,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Console.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Console.border),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Console.border),
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.selected, required this.onSelected});

  final RecordingFilter selected;
  final ValueChanged<RecordingFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: RecordingFilter.values.map((RecordingFilter item) {
          final bool active = item == selected;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              selected: active,
              onSelected: (_) => onSelected(item),
              label: Text(_filterLabel(item)),
              labelStyle: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: active ? Console.ink : const Color(0xFF9CB3C7),
              ),
              selectedColor: Console.cyan,
              backgroundColor: Console.surfaceRaised,
              side: BorderSide.none,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _MetricsRow extends StatelessWidget {
  const _MetricsRow({
    required this.total,
    required this.reviewed,
    required this.running,
    required this.failed,
  });

  final int total;
  final int reviewed;
  final int running;
  final int failed;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _AnimatedMetricCard(
                value: reviewed,
                suffix: '/$total',
                label: 'REVIEWED',
                accent: Console.green,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _AnimatedMetricCard(value: running, label: 'RUNNING'),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _AnimatedMetricCard(
                value: failed,
                label: 'FAILED',
                accent: failed == 0 ? Console.green : Console.red,
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: total == 0 ? 0 : reviewed / total),
            duration: const Duration(milliseconds: 550),
            curve: Curves.easeOutCubic,
            builder: (BuildContext context, double value, Widget? child) {
              return LinearProgressIndicator(
                value: value,
                minHeight: 5,
                color: Console.green,
                backgroundColor: const Color(0xFF17314B),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AnimatedMetricCard extends StatelessWidget {
  const _AnimatedMetricCard({
    required this.value,
    required this.label,
    this.suffix = '',
    this.accent = Console.cyan,
  });

  final int value;
  final String suffix;
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Console.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Console.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            transitionBuilder: (Widget child, Animation<double> animation) {
              return ScaleTransition(
                scale: CurvedAnimation(
                    parent: animation, curve: Curves.easeOutBack),
                child: FadeTransition(opacity: animation, child: child),
              );
            },
            child: Text(
              '$value$suffix',
              key: ValueKey<String>('$value$suffix'),
              style: TextStyle(
                color: accent,
                fontSize: 19,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              color: Console.muted,
              fontSize: 8,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordingCard extends StatelessWidget {
  const _RecordingCard({
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
                AnimatedContainer(
                  duration: const Duration(milliseconds: 350),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: reviewed
                        ? const Color(0xFF194E40)
                        : const Color(0xFF143C54),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    reviewed ? Icons.done_all_rounded : _typeIcon(recording.type),
                    color: reviewed ? Console.green : Console.cyan,
                  ),
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
                  Semantics(
                    button: true,
                    label: isPlaying ? 'Stop playback' : 'Play recording',
                    child: InkResponse(
                      onTap: onTogglePlay,
                      radius: 25,
                      child: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isPlaying
                              ? const Color(0xFF143C54)
                              : const Color(0xFF102434),
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(
                            color: isPlaying ? Console.cyan : Console.border,
                          ),
                        ),
                        child: Icon(
                          isPlaying
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          color: Console.cyan,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Semantics(
                  button: true,
                  label: 'Edit title and text',
                  child: InkResponse(
                    onTap: onEdit,
                    radius: 25,
                    child: Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFF102434),
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(color: Console.border),
                      ),
                      child: const Icon(
                        Icons.edit_outlined,
                        color: Console.cyan,
                        size: 20,
                      ),
                    ),
                  ),
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

String _filterLabel(RecordingFilter filter) => switch (filter) {
      RecordingFilter.queue => 'Queue',
      RecordingFilter.ready => 'Ready',
      RecordingFilter.failed => 'Failed',
      RecordingFilter.raw => 'Raw',
    };

String _sectionTitle(RecordingFilter filter) => switch (filter) {
      RecordingFilter.queue => 'PROCESSING QUEUE',
      RecordingFilter.ready => 'READY TRANSCRIPTS',
      RecordingFilter.failed => 'FAILED JOBS',
      RecordingFilter.raw => 'ALL LOCAL CAPTURES',
    };

String _emptyLabel(RecordingFilter filter) => switch (filter) {
      RecordingFilter.queue => 'The processing queue is empty.',
      RecordingFilter.ready => 'No completed transcripts yet.',
      RecordingFilter.failed => 'No failed transcription jobs.',
      RecordingFilter.raw => 'No local recordings yet.',
    };
