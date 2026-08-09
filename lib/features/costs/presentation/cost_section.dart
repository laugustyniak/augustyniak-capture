import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/price_book.dart';
import '../domain/usage_event.dart';

/// The editor's `COST` section: one line per API call this capture made, plus
/// what its stored source costs to keep every month.
///
/// Same shape as `RevisionHistorySection` — a header row that toggles a body —
/// but expanded by default rather than collapsed: a change history is
/// reference material nobody needs on every open, while what a capture cost is
/// closer to the point of the whole feature. It is a **pure, testable widget**
/// on purpose: it takes the events it renders rather than a repository, so it
/// never touches SQLite and a widget test never needs a database. Resolving a
/// capture's events to this list — and deciding whether there are any at all —
/// is the caller's job; a capture with none (a text note, which makes no API
/// call; a legacy row from before this feature existed) shows nothing here
/// rather than an empty panel.
///
/// It paints `Console` palette colours, so — like every widget in
/// `ui_kit.dart` and every section built the same way — it takes a plain
/// constructor rather than a `const` one; a `const` constructor would keep
/// painting the previous theme after a swap (`test/theme_test.dart` enforces
/// this).
class CostSection extends StatefulWidget {
  CostSection({
    super.key,
    required this.events,
    required this.sizeBytes,
    required this.storagePrice,
  });

  /// This capture's usage events, oldest first or newest first — the order the
  /// caller already holds them in. Empty means "nothing to show", not
  /// "nothing happened": the section renders nothing at all rather than an
  /// empty panel, the same rule `RevisionHistorySection` follows.
  final List<UsageEvent> events;

  /// The capture's own source size, so the section can report what keeping it
  /// costs — a fact the events list alone cannot answer, since a capture with
  /// no API calls (a text note) still occupies storage.
  final int sizeBytes;
  final StoragePrice storagePrice;

  @override
  State<CostSection> createState() => _CostSectionState();
}

class _CostSectionState extends State<CostSection> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    if (widget.events.isEmpty) return const SizedBox.shrink();
    final int count = widget.events.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          button: true,
          expanded: _expanded,
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 16,
                    color: Console.muted,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: SectionHeader(
                      title: 'COST',
                      trailing: '$count call${count == 1 ? '' : 's'}',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded) ...<Widget>[
          const SizedBox(height: 6),
          for (final UsageEvent event in widget.events)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(
                _eventLine(event),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ConsoleText.micro.copyWith(
                  color: event.costUsd == null ? Console.amber : Console.text,
                ),
              ),
            ),
          // Dropped entirely rather than shown as `0 B · $0.0000/mo` on a
          // legacy row with no recorded size — a monthly figure computed off
          // an unknown size is exactly the kind of fabricated zero this
          // feature exists to refuse to print.
          if (formatBytes(widget.sizeBytes) != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                _storageLine(widget.sizeBytes, widget.storagePrice),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ConsoleText.micro.copyWith(color: Console.dimText),
              ),
            ),
        ],
      ],
    );
  }
}

/// `TRANSCRIPTION · gpt-transcribe · 90 s · $0.0068` — or, unpriced,
/// `ENRICHMENT · gpt-5.6-luna · 1 200 in / 90 out · no rate`. The amount is
/// never a fabricated `$0.0000`: null means unknown, and the reason takes its
/// place instead.
String _eventLine(UsageEvent event) => <String>[
  event.stage.label,
  event.model.isEmpty ? '—' : event.model,
  _quantities(event),
  _amount(event),
].join(' · ');

/// `90 s` for a stage billed by audio time, `1 200 in / 90 out` for one billed
/// by tokens. Either quantity can be null — the provider reported none and the
/// capture could not supply a fallback — which reads as `—` rather than
/// crashing on a null `.round()`.
String _quantities(UsageEvent event) {
  if (event.stage == UsageStage.transcription) {
    final double? seconds = event.audioSeconds;
    return seconds == null ? '— s' : '${seconds.round()} s';
  }
  final String input = event.inputTokens == null
      ? '—'
      : _grouped(event.inputTokens!);
  final String output = event.outputTokens == null
      ? '—'
      : _grouped(event.outputTokens!);
  return '$input in / $output out';
}

/// [formatUsd] when the event was priced; otherwise the reason in words. The
/// two reasons are deliberately worded differently — `no rate` is fixable in
/// the Config tab, `unknown duration` is not — mirroring the distinction
/// `UnpricedReason` documents.
String _amount(UsageEvent event) {
  final double? cost = event.costUsd;
  if (cost != null) return formatUsd(cost);
  return switch (event.unpricedReason) {
    UnpricedReason.noRate => 'no rate',
    UnpricedReason.noQuantity => 'unknown duration',
    // Not reachable in practice — `unpricedReason` is set exactly when
    // `costUsd` is null — but a fallback keeps this total rather than partial.
    null => 'no rate',
  };
}

/// `1 200`, not `1200` — a plain space every three digits, with no `intl`
/// dependency to pull in for one call site.
String _grouped(int value) {
  final String digits = value.abs().toString();
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return value < 0 ? '-$buffer' : buffer.toString();
}

/// `6.8 MB · $0.0034/mo` — the same storage formula the Config tab's PRICING
/// section already uses, so the two never disagree about what a capture's
/// source costs to keep. Callers only reach this once [formatBytes] has
/// already proven [sizeBytes] is a real measurement, so the `!` here can never
/// fire — the null case is handled by not calling this at all.
String _storageLine(int sizeBytes, StoragePrice storagePrice) {
  final double monthly = sizeBytes / 1073741824 *
      (storagePrice.r2PerGbMonth + storagePrice.tursoPerGbMonth);
  return '${formatBytes(sizeBytes)!} · ${formatUsd(monthly)}/mo';
}
