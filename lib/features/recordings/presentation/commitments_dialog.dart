import 'package:flutter/material.dart';

import '../domain/commitment.dart';
import '../domain/commitment_list.dart';
import '../domain/recording.dart';

/// Open commitments across every capture, soonest due first (#251).
///
/// Listens to [listenable] — the controller in the app — so marking one done
/// or dismissed takes it off the list as soon as the write lands. Each row
/// links back to its capture and can be exported as an `.ics` file; the
/// dialog itself never writes anything, every action goes through a callback.
class CommitmentsDialog extends StatelessWidget {
  const CommitmentsDialog({
    super.key,
    required this.listenable,
    required this.captures,
    required this.onSetState,
    required this.onExport,
    required this.onOpenCapture,
  });

  final Listenable listenable;
  final List<Recording> Function() captures;
  final Future<void> Function(
    String recordingId,
    Commitment commitment,
    CommitmentState state,
  )
  onSetState;
  final Future<void> Function(Recording recording, Commitment commitment)
  onExport;
  final ValueChanged<Recording> onOpenCapture;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Commitments'),
      content: SizedBox(
        width: 620,
        child: ListenableBuilder(
          listenable: listenable,
          builder: (BuildContext context, _) {
            final List<CommitmentEntry> entries = openCommitments(captures());
            if (entries.isEmpty) {
              return const Text('No open commitments.');
            }
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final CommitmentEntry entry in entries)
                    _CommitmentRow(
                      key: ValueKey<String>(
                        '${entry.recording.id}/${entry.commitment.key}',
                      ),
                      entry: entry,
                      onSetState: onSetState,
                      onExport: onExport,
                      onOpenCapture: (Recording recording) {
                        Navigator.of(context).maybePop();
                        onOpenCapture(recording);
                      },
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('CLOSE'),
        ),
      ],
    );
  }
}

class _CommitmentRow extends StatelessWidget {
  const _CommitmentRow({
    super.key,
    required this.entry,
    required this.onSetState,
    required this.onExport,
    required this.onOpenCapture,
  });

  final CommitmentEntry entry;
  final Future<void> Function(String, Commitment, CommitmentState) onSetState;
  final Future<void> Function(Recording, Commitment) onExport;
  final ValueChanged<Recording> onOpenCapture;

  @override
  Widget build(BuildContext context) {
    final Commitment commitment = entry.commitment;
    final Recording recording = entry.recording;
    final MaterialLocalizations l10n = MaterialLocalizations.of(context);
    final DateTime? due = commitment.due;
    final String? title = recording.title?.trim();
    final String source = title != null && title.isNotEmpty
        ? title
        : 'Capture ${l10n.formatMediumDate(recording.createdAt)}';
    final List<String> meta = <String>[
      due == null ? 'No due date' : 'Due ${l10n.formatMediumDate(due)}',
      if (commitment.who != null) commitment.who!,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  commitment.text,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  meta.join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                InkWell(
                  onTap: () => onOpenCapture(recording),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      source,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Export ${commitment.text}',
            icon: const Icon(Icons.event_outlined),
            onPressed: () => onExport(recording, commitment),
          ),
          IconButton(
            tooltip: 'Mark ${commitment.text} done',
            icon: const Icon(Icons.check),
            onPressed: () =>
                onSetState(recording.id, commitment, CommitmentState.done),
          ),
          IconButton(
            tooltip: 'Dismiss ${commitment.text}',
            icon: const Icon(Icons.close),
            onPressed: () =>
                onSetState(recording.id, commitment, CommitmentState.dismissed),
          ),
        ],
      ),
    );
  }
}
