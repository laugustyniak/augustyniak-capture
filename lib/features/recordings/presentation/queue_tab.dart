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

/// The five buckets from the design. They **partition** the queue: every item
/// matches exactly one of `queue`/`ready`/`failed`/`raw`, and `all` is their
/// union — which is what lets each chip carry a count that adds up.
enum RecordingFilter { all, queue, ready, failed, raw }

/// The original Phase-1 screen: header, review progress, search, status filters
/// and the capture list. Owns only view state; every mutation goes through
/// [RecordingsController].
class QueueTab extends StatefulWidget {
  const QueueTab({super.key, required this.controller});

  final RecordingsController controller;

  @override
  State<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<QueueTab> {
  RecordingFilter selectedFilter = RecordingFilter.all;
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
    final List<Recording> all = controller.recordings;
    final List<Recording> visible = _filter(all);
    final int reviewedCount =
        all.where((Recording item) => item.isProcessedByUser).length;

    return SafeArea(
      bottom: false,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: ConsoleHeader(
              title: 'Queue',
              trailing:
                  '${all.length} ${all.length == 1 ? 'capture' : 'captures'}',
            ),
          ),
          if (controller.error != null) ...<Widget>[
            const SizedBox(height: 10),
            ErrorBanner(message: controller.error!),
          ],
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 190),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ReviewedStrip(
                    total: all.length,
                    reviewed: reviewedCount,
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _SearchField(
                    controller: searchController,
                    value: searchQuery,
                    onChanged: (String value) {
                      setState(() => searchQuery = value);
                    },
                  ),
                ),
                const SizedBox(height: 12),
                _FilterRow(
                  selected: selectedFilter,
                  // Counted before the search is applied: the chips describe
                  // the queue, not the current query — otherwise every count
                  // would collapse to whatever the user last typed.
                  counts: <RecordingFilter, int>{
                    for (final RecordingFilter filter in RecordingFilter.values)
                      filter: all
                          .where((Recording item) => _matches(filter, item))
                          .length,
                  },
                  onSelected: (RecordingFilter value) {
                    setState(() => selectedFilter = value);
                  },
                ),
                const SizedBox(height: 14),
                if (visible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: EmptyPanel(
                      icon: Icons.graphic_eq,
                      title: _emptyLabel(selectedFilter),
                      blurb: 'Every capture is written to disk and verified '
                          'before processing is even attempted.',
                    ),
                  )
                else
                  ...visible.map(
                    (Recording recording) => Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
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
    final List<Recording> byStatus = recordings
        .where((Recording item) => _matches(selectedFilter, item))
        .toList();
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
    await widget.controller.setCategory(recording.id, result.category);
  }
}

/// Single definition of what each bucket contains — used both to filter the
/// list and to count the chips, so the two can never disagree.
bool _matches(RecordingFilter filter, Recording item) => switch (filter) {
      RecordingFilter.all => true,
      RecordingFilter.queue =>
        item.status == RecordingStatus.pendingTranscription ||
            item.status == RecordingStatus.transcribing,
      RecordingFilter.ready => item.status == RecordingStatus.completed,
      RecordingFilter.failed => item.status == RecordingStatus.failed,
      // Persisted and verified, but not handed to a processor yet.
      RecordingFilter.raw => item.status == RecordingStatus.saved,
    };

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
    const OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(10)),
      borderSide: BorderSide(color: Console.border),
    );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(color: Console.text, fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 13),
        hintText: 'Search captures',
        hintStyle: const TextStyle(color: Console.dim, fontSize: 13),
        prefixIcon: const Icon(Icons.search, color: Console.dim, size: 18),
        prefixIconConstraints: const BoxConstraints(minWidth: 42),
        suffixIcon: value.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, color: Console.dim, size: 18),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        filled: true,
        fillColor: Console.surface,
        border: border,
        enabledBorder: border,
        disabledBorder: border,
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: Console.borderStrong),
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.selected,
    required this.counts,
    required this.onSelected,
  });

  final RecordingFilter selected;
  final Map<RecordingFilter, int> counts;
  final ValueChanged<RecordingFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: RecordingFilter.values.map((RecordingFilter item) {
          return Padding(
            padding: const EdgeInsets.only(right: 7),
            child: ConsoleChip(
              label: item.name.toUpperCase(),
              count: counts[item] ?? 0,
              selected: item == selected,
              onSelected: () => onSelected(item),
            ),
          );
        }).toList(),
      ),
    );
  }
}

String _emptyLabel(RecordingFilter filter) => switch (filter) {
      RecordingFilter.all => 'Nothing captured yet.',
      RecordingFilter.queue => 'The processing queue is empty.',
      RecordingFilter.ready => 'No finished output yet.',
      RecordingFilter.failed => 'No failed jobs.',
      RecordingFilter.raw => 'Nothing waiting to be queued.',
    };
