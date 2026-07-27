import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../domain/recording.dart';
import 'edit_sheet.dart';
import 'queue_metrics.dart';
import 'recording_card.dart';
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
                MetricsRow(
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
                      child: RecordingCard(
                        recording: recording,
                        isPlaying: controller.playingId == recording.id,
                        onTogglePlay: () =>
                            controller.togglePlayback(recording.id),
                        onRetry: () =>
                            controller.retryTranscription(recording.id),
                        onEdit: () => _openEditSheet(context, recording),
                        onToggleProcessed: () async {
                          // Fire-and-forget: the haptic is cosmetic and must
                          // not gate a durable state write. Awaiting it means
                          // the review flag waits on the platform answering —
                          // which, on a host that never does, is forever.
                          unawaited(HapticFeedback.selectionClick());
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
    final EditResult? result = await showModalBottomSheet<EditResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Console.background,
      builder: (BuildContext _) => EditSheet(recording: recording),
    );
    if (result == null) return; // cancelled
    await widget.controller.setTitle(recording.id, result.title);
    await widget.controller.editTranscript(recording.id, result.transcript);
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
      // Only this label changes on a tick, so only this label subscribes to the
      // ticker. The surrounding page rebuilds on real state changes instead of
      // four times a second.
      label: ValueListenableBuilder<Duration>(
        valueListenable: controller.elapsedTicker,
        builder: (BuildContext context, Duration elapsed, Widget? child) {
          return Text(
            recording
                ? 'SAVE ${formatDuration(elapsed)}'
                : controller.isBusy
                    ? 'PROCESSING'
                    : 'CAPTURE',
            style: const TextStyle(fontWeight: FontWeight.w900),
          );
        },
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
            child: ConsoleChip(
              label: _filterLabel(item),
              selected: active,
              onSelected: () => onSelected(item),
            ),
          );
        }).toList(),
      ),
    );
  }
}



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
