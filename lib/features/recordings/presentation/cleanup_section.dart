import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/cleanup_proposal.dart';
import '../domain/recording.dart';
import '../domain/word_diff.dart';

/// The editor's `CLEAN-UP` block (#258): ask for a cleaned transcript, then
/// read it as a diff against the current one and accept or reject it.
///
/// A pure widget over the recording and four callbacks, like
/// `RevisionHistorySection`. The controller decides; this only renders which
/// of four states the item is in — idle, cleaning, a proposal, a stale
/// proposal.
class CleanupSection extends StatelessWidget {
  CleanupSection({
    super.key,
    required this.recording,
    required this.cleaning,
    this.error,
    this.onCleanUp,
    this.onAccept,
    this.onReject,
    this.acceptBlockedReason,
  });

  static const String cleanUpLabel = 'CLEAN UP';
  static const String acceptLabel = 'ACCEPT';
  static const String rejectLabel = 'REJECT';

  final Recording recording;
  final bool cleaning;

  /// Why the last attempt produced nothing. Shown only while idle.
  final String? error;

  /// Null hides the CLEAN UP button: a typed note, or a host with no model.
  final VoidCallback? onCleanUp;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;

  /// Non-null disables ACCEPT and says why — an unsaved edit in the text
  /// field, which the accept would otherwise race.
  final String? acceptBlockedReason;

  @override
  Widget build(BuildContext context) {
    final CleanupProposal? proposal = recording.cleanup;
    final bool stale =
        proposal != null && !proposal.matches(recording.transcript);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: SectionHeader(
                title: 'CLEAN-UP',
                trailing: cleaning
                    ? 'CLEANING UP…'
                    : proposal == null
                    ? null
                    : (stale ? 'STALE' : 'PROPOSED'),
              ),
            ),
            if (!cleaning && proposal == null && onCleanUp != null) ...<Widget>[
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: onCleanUp,
                icon: const Icon(Icons.auto_fix_high, size: 15),
                label: const Text(cleanUpLabel),
              ),
            ],
          ],
        ),
        if (!cleaning && proposal == null && error != null)
          Text(error!, style: ConsoleText.micro.copyWith(color: Console.amber)),
        if (proposal != null && !cleaning) ...<Widget>[
          const SizedBox(height: 6),
          if (stale)
            Text(
              'The text changed after this was proposed. Accepting it would '
              'undo that change.',
              style: ConsoleText.micro.copyWith(color: Console.amber),
            )
          else
            _DiffView(before: recording.transcript ?? '', after: proposal.text),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              if (acceptBlockedReason != null && !stale)
                Expanded(
                  child: Text(
                    acceptBlockedReason!,
                    style: ConsoleText.micro.copyWith(color: Console.amber),
                  ),
                )
              else
                const Spacer(),
              TextButton(onPressed: onReject, child: const Text(rejectLabel)),
              if (stale)
                TextButton(
                  onPressed: onCleanUp,
                  child: const Text('CLEAN UP AGAIN'),
                )
              else
                TextButton(
                  onPressed: acceptBlockedReason == null ? onAccept : null,
                  child: const Text(acceptLabel),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Removed words struck through in red, added ones in green, the rest as
/// body text. Falls back to the proposal alone when the diff is too big to
/// compute in a frame.
class _DiffView extends StatelessWidget {
  _DiffView({required this.before, required this.after});

  final String before;
  final String after;

  @override
  Widget build(BuildContext context) {
    final List<DiffSpan>? spans = wordDiff(before, after);
    final TextStyle base = TextStyle(
      color: Console.text,
      fontSize: 12,
      height: 1.5,
    );
    final InlineSpan text = spans == null
        ? TextSpan(text: after, style: base)
        : TextSpan(
            style: base,
            children: <InlineSpan>[
              for (final DiffSpan span in spans)
                TextSpan(
                  // A removed last word carries no trailing space, so it would
                  // run straight into the words that replace it.
                  text:
                      span.kind == DiffKind.removed &&
                          span.text.trimRight() == span.text
                      ? '${span.text} '
                      : span.text,
                  style: switch (span.kind) {
                    DiffKind.same => null,
                    DiffKind.removed => TextStyle(
                      color: Console.red,
                      decoration: TextDecoration.lineThrough,
                      decorationColor: Console.red,
                    ),
                    DiffKind.added => TextStyle(
                      color: Console.green,
                      backgroundColor: Console.green.withValues(alpha: .12),
                    ),
                  },
                ),
            ],
          );

    return Container(
      constraints: const BoxConstraints(maxHeight: 280),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Console.surfaceDeep,
        border: Border.all(color: Console.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(child: Text.rich(text)),
    );
  }
}
