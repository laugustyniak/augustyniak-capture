import 'package:flutter/material.dart';

import '../../recordings/domain/capture_priority.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../domain/daily_triage.dart';
import 'daily_triage_controller.dart';

/// Acceptance through the same entry points the queue's own buttons use.
class RecordingsTriageActions implements TriageActions {
  RecordingsTriageActions(this._controller);

  final RecordingsController _controller;

  @override
  Future<void> close(String id) async {
    final Recording? recording = _controller.recordings
        .where((Recording item) => item.id == id)
        .firstOrNull;
    if (recording == null || recording.isProcessedByUser) return;
    await _controller.toggleProcessed(id);
  }

  @override
  Future<void> setPriority(String id, CapturePriority priority) =>
      _controller.setPriority(id, priority);
}

class DailyTriageDialog extends StatelessWidget {
  const DailyTriageDialog({
    super.key,
    required this.triage,
    required this.captures,
    required this.onOpenCapture,
  });

  final DailyTriageController triage;
  final List<Recording> Function() captures;
  final ValueChanged<Recording> onOpenCapture;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: triage,
      builder: (BuildContext context, _) {
        final Map<String, Recording> byId = <String, Recording>{
          for (final Recording capture in captures()) capture.id: capture,
        };
        final List<TriageProposal> proposals = triage.proposals;
        final TriageDigest? digest = triage.digest;
        return AlertDialog(
          title: const Text('Daily triage'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    'Proposes duplicates to merge, captures to close, stale items and re-ranks. Titles, summaries and text excerpts of open captures go to your active enrichment model, which may charge for the run. Nothing changes until you accept a proposal.',
                  ),
                  if (digest != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      'Last run ${MaterialLocalizations.of(context).formatMediumDate(digest.at.toLocal())} '
                      '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(digest.at.toLocal()))}',
                    ),
                  ],
                  if (triage.historyUnreadable) ...<Widget>[
                    const SizedBox(height: 8),
                    const Text(
                      'Earlier triage answers could not be read, so triage does not run on its own this session.',
                    ),
                  ],
                  if (triage.isRunning) ...<Widget>[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    const Text('Triaging open captures…'),
                  ],
                  if (triage.error case final String error) ...<Widget>[
                    const SizedBox(height: 16),
                    Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (digest != null && !triage.isRunning) ...<Widget>[
                    const SizedBox(height: 16),
                    if (proposals.isEmpty)
                      const Text('Nothing to triage right now.'),
                    for (final TriageProposal proposal in proposals)
                      ..._proposal(context, proposal, byId),
                  ],
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('CLOSE'),
            ),
            FilledButton(
              onPressed: triage.isRunning ? null : triage.run,
              child: const Text('RUN TRIAGE'),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _proposal(
    BuildContext context,
    TriageProposal proposal,
    Map<String, Recording> byId,
  ) => <Widget>[
    const Divider(height: 24),
    Text(_label(proposal), style: Theme.of(context).textTheme.titleMedium),
    const SizedBox(height: 4),
    Text(proposal.reason),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      runSpacing: 4,
      children: <Widget>[
        for (final String id in proposal.captureIds)
          if (byId[id] case final Recording capture)
            ActionChip(
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text(
                  capture.title?.trim().isNotEmpty == true
                      ? capture.title!
                      : 'Capture ${id.length <= 8 ? id : id.substring(0, 8)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              onPressed: () {
                Navigator.of(context).pop();
                onOpenCapture(capture);
              },
            ),
      ],
    ),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      children: <Widget>[
        FilledButton.tonal(
          onPressed: () => triage.accept(proposal),
          child: Text(_acceptLabel(proposal)),
        ),
        TextButton(
          onPressed: () => triage.reject(proposal),
          child: const Text('REJECT'),
        ),
      ],
    ),
  ];

  static String _label(TriageProposal proposal) => switch (proposal.kind) {
    TriageKind.merge => 'Duplicates',
    TriageKind.close => 'Looks done',
    TriageKind.stale => 'Stale',
    TriageKind.rerank => 'Re-rank to ${proposal.priority!.label}',
  };

  static String _acceptLabel(TriageProposal proposal) =>
      switch (proposal.kind) {
        TriageKind.merge => 'KEEP OLDEST, CLOSE REST',
        TriageKind.close || TriageKind.stale => 'CLOSE',
        TriageKind.rerank => 'SET ${proposal.priority!.label}',
      };
}
