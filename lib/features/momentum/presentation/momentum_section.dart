import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/closure_event.dart';

/// The Config panel for the closure history — one button, and it is a backfill.
///
/// **The same role `MIRROR EVERYTHING` plays for the note vault**, and it exists
/// for the same reason: a history that only counts closures made *after* the
/// feature shipped leaves an existing queue permanently outside it. An install
/// with a hundred captures already off the desk would open the panel on
/// "Nothing closed yet" and a target of 1 — a record starting at zero for
/// somebody whose work is all behind them, with no way in short of re-closing
/// everything by hand.
class MomentumSection extends StatefulWidget {
  MomentumSection({super.key, this.onBackfill});

  /// Null disables the button — the seam shape the vault section uses, so a
  /// host with nothing to sweep renders the panel greyed rather than absent.
  final Future<ClosureBackfill> Function()? onBackfill;

  @override
  State<MomentumSection> createState() => _MomentumSectionState();
}

class _MomentumSectionState extends State<MomentumSection> {
  bool _sweeping = false;
  ClosureBackfill? _summary;

  Future<void> _backfill() async {
    final Future<ClosureBackfill> Function()? sweep = widget.onBackfill;
    if (sweep == null || _sweeping) return;
    setState(() => _sweeping = true);
    try {
      final ClosureBackfill summary = await sweep();
      if (!mounted) return;
      setState(() => _summary = summary);
    } finally {
      if (mounted) setState(() => _sweeping = false);
    }
  }

  /// Counts rather than a list, and every non-zero one is named.
  ///
  /// `undatable` is reported instead of being folded into the total because it
  /// is the one number the user cannot act on: those rows were closed before
  /// the app recorded *when*, and inventing a date would put something that
  /// never happened into an append-only file.
  String _report(ClosureBackfill summary) {
    if (summary.isEmpty) return 'Nothing to record — no capture is closed yet.';
    final List<String> parts = <String>[
      if (summary.recorded > 0) '${summary.recorded} recorded',
      if (summary.alreadyKnown > 0) '${summary.alreadyKnown} already counted',
      if (summary.undatable > 0) '${summary.undatable} with no closing date',
      if (summary.failed > 0) '${summary.failed} failed',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final ClosureBackfill? summary = _summary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHeader(title: 'MOMENTUM'),
        const SizedBox(height: 12),
        ConsoleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'The Timer tab counts what leaves the desk each day and sets '
                'tomorrow\'s target from your own pace. Captures you closed '
                'before this existed are not in that history yet — this reads '
                'them back from the queue, dating each one by when it was '
                'actually closed.',
                style: ConsoleText.micro.copyWith(height: 1.45),
              ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  Expanded(
                    child: summary == null
                        ? const SizedBox.shrink()
                        : Text(
                            _report(summary),
                            style: ConsoleText.micro.copyWith(
                              color: summary.failed > 0
                                  ? Console.amber
                                  : Console.dimText,
                            ),
                          ),
                  ),
                  if (_sweeping)
                    Text(
                      'READING…',
                      style: ConsoleText.micro.copyWith(color: Console.accent),
                    )
                  else
                    TextButton.icon(
                      // Disabled rather than hidden, like the vault sweep: the
                      // user came to this panel on purpose, and a greyed
                      // control explains itself where a missing one cannot.
                      onPressed: widget.onBackfill == null ? null : _backfill,
                      icon: const Icon(Icons.history_rounded, size: 17),
                      label: const Text('RECORD PAST CLOSURES'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
