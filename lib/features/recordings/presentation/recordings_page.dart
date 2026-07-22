import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../transcription/data/transcription_service.dart';
import '../data/recordings_repository.dart';
import '../domain/recording.dart';
import 'recordings_controller.dart';

enum RecordingFilter { queue, ready, failed, raw }

class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  late final RecordingsController controller;
  RecordingFilter selectedFilter = RecordingFilter.queue;
  int navigationIndex = 0;

  @override
  void initState() {
    super.initState();
    controller = RecordingsController(
      repository: RecordingsRepository(),
      transcriptionService: const DisabledTranscriptionService(),
    )..initialize();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final List<Recording> visible = _filter(controller.recordings);
        final int processingCount = controller.recordings
            .where((Recording item) =>
                item.status == RecordingStatus.pendingTranscription ||
                item.status == RecordingStatus.transcribing)
            .length;
        final int failedCount = controller.recordings
            .where((Recording item) => item.status == RecordingStatus.failed)
            .length;
        final int reviewedCount = controller.recordings
            .where((Recording item) => item.isProcessedByUser)
            .length;

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 20,
            title: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Audivoa Core',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 21),
                ),
                Text(
                  'LOCAL-FIRST PROCESSING CONSOLE',
                  style: TextStyle(
                    color: Color(0xFF6F8CA5),
                    fontSize: 9,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              Padding(
                padding: const EdgeInsets.only(right: 18),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFF31D5F4),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    'AI',
                    style: TextStyle(
                      color: Color(0xFF00131A),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: <Widget>[
                if (controller.error != null)
                  _ErrorBanner(message: controller.error!),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 110),
                    children: <Widget>[
                      const _SearchField(),
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          Text(
                            _sectionTitle(selectedFilter),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              letterSpacing: .2,
                            ),
                          ),
                          Text(
                            '${visible.length} ITEMS',
                            style: const TextStyle(
                              color: Color(0xFF6F8CA5),
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (visible.isEmpty)
                        _EmptyState(filter: selectedFilter)
                      else
                        ...visible.map(
                          (Recording recording) => Padding(
                            padding: const EdgeInsets.only(bottom: 11),
                            child: _RecordingCard(
                              recording: recording,
                              onRetry: () =>
                                  controller.retryTranscription(recording.id),
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
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          floatingActionButton: _RecordButton(controller: controller),
          bottomNavigationBar: NavigationBar(
            selectedIndex: navigationIndex,
            onDestinationSelected: (int value) {
              setState(() => navigationIndex = value);
            },
            destinations: const <NavigationDestination>[
              NavigationDestination(
                icon: Icon(Icons.inbox_outlined),
                selectedIcon: Icon(Icons.inbox),
                label: 'Queue',
              ),
              NavigationDestination(
                icon: Icon(Icons.memory_outlined),
                selectedIcon: Icon(Icons.memory),
                label: 'Models',
              ),
              NavigationDestination(
                icon: Icon(Icons.terminal_outlined),
                selectedIcon: Icon(Icons.terminal),
                label: 'Logs',
              ),
              NavigationDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: 'Config',
              ),
            ],
          ),
        );
      },
    );
  }

  List<Recording> _filter(List<Recording> recordings) {
    return switch (selectedFilter) {
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
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField();

  @override
  Widget build(BuildContext context) {
    return TextField(
      enabled: false,
      decoration: InputDecoration(
        hintText: 'Search recordings and transcripts',
        hintStyle: const TextStyle(color: Color(0xFF6F8CA5), fontSize: 13),
        prefixIcon: const Icon(Icons.search, color: Color(0xFF6F8CA5)),
        suffixIcon: Padding(
          padding: const EdgeInsets.all(11),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF2A4862)),
              borderRadius: BorderRadius.circular(7),
            ),
            alignment: Alignment.center,
            child: const Text(
              '⌘K',
              style: TextStyle(fontSize: 9, color: Color(0xFF8EABC2)),
            ),
          ),
        ),
        filled: true,
        fillColor: const Color(0xFF0C1D2E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFF1B3852)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFF1B3852)),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFF1B3852)),
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
                color: active
                    ? const Color(0xFF00131A)
                    : const Color(0xFF9CB3C7),
              ),
              selectedColor: const Color(0xFF31D5F4),
              backgroundColor: const Color(0xFF112B42),
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
                accent: const Color(0xFF4ADE80),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _AnimatedMetricCard(
                value: running,
                label: 'RUNNING',
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _AnimatedMetricCard(
                value: failed,
                label: 'FAILED',
                accent: failed == 0
                    ? const Color(0xFF4ADE80)
                    : const Color(0xFFFF6B81),
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
                color: const Color(0xFF4ADE80),
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
    this.accent = const Color(0xFF31D5F4),
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
        color: const Color(0xFF10243A),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFF1B3852)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            transitionBuilder: (Widget child, Animation<double> animation) {
              return ScaleTransition(
                scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
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
              color: Color(0xFF6F8CA5),
              fontSize: 8,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.value,
    required this.label,
    this.accent = const Color(0xFF31D5F4),
  });

  final String value;
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF10243A),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFF1B3852)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              color: accent,
              fontSize: 19,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF6F8CA5),
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
    required this.onRetry,
    required this.onToggleProcessed,
  });

  final Recording recording;
  final VoidCallback onRetry;
  final VoidCallback onToggleProcessed;

  @override
  Widget build(BuildContext context) {
    final bool canRetry = recording.status == RecordingStatus.failed;
    final bool reviewed = recording.isProcessedByUser;
    final _StatusVisual visual = _statusVisual(recording.status);
    final String filename = File(recording.filePath).uri.pathSegments.last;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: reviewed ? const Color(0xFF102C31) : const Color(0xFF10243A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: reviewed ? const Color(0xFF2F8B68) : const Color(0xFF1B3852),
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
                    reviewed ? Icons.done_all_rounded : Icons.graphic_eq,
                    color: reviewed
                        ? const Color(0xFF4ADE80)
                        : const Color(0xFF31D5F4),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_date(recording.createdAt)} · ${_formatDuration(Duration(milliseconds: recording.durationMs))}',
                        style: const TextStyle(
                          color: Color(0xFF7894AA),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
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
                        color: reviewed
                            ? const Color(0xFF4ADE80)
                            : const Color(0xFF6F8CA5),
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
                _StatusPill(label: visual.label, color: visual.color),
                const _StatusPill(
                  label: 'LOCAL FILE VERIFIED',
                  color: Color(0xFF4ADE80),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: reviewed
                      ? const _StatusPill(
                          key: ValueKey<String>('reviewed'),
                          label: 'REVIEWED BY YOU',
                          color: Color(0xFF4ADE80),
                        )
                      : const _StatusPill(
                          key: ValueKey<String>('unreviewed'),
                          label: 'NEEDS REVIEW',
                          color: Color(0xFFFBBF24),
                        ),
                ),
              ],
            ),
            if (recording.status == RecordingStatus.transcribing) ...<Widget>[
              const SizedBox(height: 12),
              const LinearProgressIndicator(
                minHeight: 4,
                color: Color(0xFF31D5F4),
                backgroundColor: Color(0xFF1A3A51),
              ),
            ],
            if (recording.transcript != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                recording.transcript!,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFC8D7E4),
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ],
            if (recording.error != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                recording.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFFF8FA1), fontSize: 10),
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

class _StatusPill extends StatelessWidget {
  const _StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w900,
          letterSpacing: .25,
        ),
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.controller});

  final RecordingsController controller;

  @override
  Widget build(BuildContext context) {
    final bool recording = controller.isRecording;
    return FloatingActionButton.extended(
      heroTag: 'record',
      backgroundColor: recording
          ? const Color(0xFFFF6B81)
          : const Color(0xFF31D5F4),
      foregroundColor: const Color(0xFF00131A),
      onPressed: controller.isBusy
          ? null
          : recording
              ? controller.stopRecording
              : controller.startRecording,
      icon: Icon(recording ? Icons.stop_rounded : Icons.mic_rounded),
      label: Text(
        recording
            ? 'SAVE ${_formatDuration(controller.elapsed)}'
            : controller.isBusy
                ? 'PROCESSING'
                : 'CAPTURE',
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filter});

  final RecordingFilter filter;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 42),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1D2E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF1B3852)),
      ),
      child: Column(
        children: <Widget>[
          const Icon(Icons.graphic_eq, size: 42, color: Color(0xFF31D5F4)),
          const SizedBox(height: 13),
          Text(
            _emptyLabel(filter),
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          const Text(
            'Audio is always persisted and verified before transcription starts.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF7894AA), fontSize: 11, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF3A1823),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF6D2A3C)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.error_outline, color: Color(0xFFFF8FA1)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: const TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

class _StatusVisual {
  const _StatusVisual(this.label, this.color);
  final String label;
  final Color color;
}

_StatusVisual _statusVisual(RecordingStatus status) => switch (status) {
      RecordingStatus.saved =>
        const _StatusVisual('SAVED · WAITING', Color(0xFFFBBF24)),
      RecordingStatus.pendingTranscription =>
        const _StatusVisual('QUEUED', Color(0xFFFBBF24)),
      RecordingStatus.transcribing =>
        const _StatusVisual('WHISPER RUNNING', Color(0xFF31D5F4)),
      RecordingStatus.completed =>
        const _StatusVisual('TRANSCRIPT READY', Color(0xFF4ADE80)),
      RecordingStatus.failed =>
        const _StatusVisual('TRANSCRIPTION FAILED', Color(0xFFFF6B81)),
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

String _formatDuration(Duration duration) {
  final String minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final String seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String _date(DateTime value) {
  final DateTime local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}
