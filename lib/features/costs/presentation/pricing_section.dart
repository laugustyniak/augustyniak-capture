import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/model_price.dart';
import '../domain/price_book.dart';

/// One editable row's controllers, keyed by rate key in [_PricingSectionState].
///
/// All three are always allocated — a row is either a chat shape (input +
/// output) or a transcription shape (audio-minute), never both, but keeping
/// one class rather than two subtypes means the row widget can stay a single
/// method with a branch instead of two near-duplicate ones.
class _RateRowControllers {
  _RateRowControllers({required this.isTranscription});

  final bool isTranscription;
  final TextEditingController input = TextEditingController();
  final TextEditingController output = TextEditingController();
  final TextEditingController audio = TextEditingController();

  void dispose() {
    input.dispose();
    output.dispose();
    audio.dispose();
  }
}

/// The Config tab's `PRICING` section — the first surface that shows any of
/// what the app has spent on AI calls, priced invisibly behind every capture
/// since Task 3.
///
/// Stateful for the same reason `EnrichmentContextSection` is: each rate row
/// owns `TextEditingController`s that must survive the host's own rebuilds
/// (settings changing elsewhere on the tab notifies this section too) without
/// losing whatever the user is mid-edit on. It paints `Console` palette
/// colours, so — like every widget in `ui_kit.dart` — it takes a plain
/// constructor; a `const` one would keep painting the previous theme after a
/// swap (`test/theme_test.dart` enforces this).
class PricingSection extends StatefulWidget {
  PricingSection({
    super.key,
    required this.thisMonthUsd,
    required this.allTimeUsd,
    required this.storageBytes,
    required this.storagePrice,
    required this.models,
    required this.priceBook,
    required this.missingRateCounts,
    required this.unknownQuantityCount,
    required this.verifiedOn,
    required this.onRateChanged,
  });

  final double thisMonthUsd;
  final double allTimeUsd;
  final int storageBytes;
  final StoragePrice storagePrice;

  /// The models actually in use, not the full shipped rate table — most
  /// installs talk to one or two providers, and the other three dozen entries
  /// in `PriceBookDefaults.rates` would swamp the section for no reason.
  final List<String> models;
  final PriceBook priceBook;

  /// Models whose events are unpriced for `UnpricedReason.noRate` — the only
  /// ones a typed rate can fix. Deliberately kept apart from
  /// [unknownQuantityCount]: no rate the user types would price those, so
  /// they must never be offered this control.
  final Map<String, int> missingRateCounts;
  final int unknownQuantityCount;
  final DateTime verifiedOn;

  /// `price == null` (or a [ModelPrice] with every field cleared) removes the
  /// override and lets the shipped default take back over.
  final void Function(String key, ModelPrice? price) onRateChanged;

  @override
  State<PricingSection> createState() => _PricingSectionState();
}

class _PricingSectionState extends State<PricingSection> {
  final Map<String, _RateRowControllers> _controllers =
      <String, _RateRowControllers>{};

  @override
  void didUpdateWidget(covariant PricingSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Drop controllers for keys that no longer appear anywhere — a model that
    // scrolled out of use. Existing keys keep their controller untouched, so
    // an in-progress edit never gets clobbered by an unrelated settings
    // change elsewhere on the tab.
    final Set<String> next = _allKeys(widget);
    for (final String key in _controllers.keys.toList()) {
      if (!next.contains(key)) _controllers.remove(key)?.dispose();
    }
  }

  @override
  void dispose() {
    for (final _RateRowControllers ctrls in _controllers.values) {
      ctrls.dispose();
    }
    super.dispose();
  }

  static Set<String> _allKeys(PricingSection w) => <String>{
    ...w.models,
    ...w.missingRateCounts.keys,
  };

  _RateRowControllers _controllersFor(String key) {
    return _controllers.putIfAbsent(key, () {
      final ModelPrice? existing = widget.priceBook.lookup(key, key);
      final bool isTranscription = existing?.perAudioMinute != null;
      final _RateRowControllers ctrls = _RateRowControllers(
        isTranscription: isTranscription,
      );
      if (isTranscription) {
        ctrls.audio.text = existing?.perAudioMinute?.toString() ?? '';
      } else {
        ctrls.input.text = existing?.inputPerMTok?.toString() ?? '';
        ctrls.output.text = existing?.outputPerMTok?.toString() ?? '';
      }
      return ctrls;
    });
  }

  double? _parse(String text) => double.tryParse(text.trim());

  void _commit(String key, _RateRowControllers ctrls) {
    final ModelPrice price = ctrls.isTranscription
        ? ModelPrice(perAudioMinute: _parse(ctrls.audio.text))
        : ModelPrice(
            inputPerMTok: _parse(ctrls.input.text),
            outputPerMTok: _parse(ctrls.output.text),
          );
    widget.onRateChanged(key, price.isEmpty ? null : price);
  }

  void _reset(String key, _RateRowControllers ctrls) {
    widget.onRateChanged(key, null);
    final ModelPrice? fallback = PriceBookDefaults.rates[key];
    setState(() {
      if (ctrls.isTranscription) {
        ctrls.audio.text = fallback?.perAudioMinute?.toString() ?? '';
      } else {
        ctrls.input.text = fallback?.inputPerMTok?.toString() ?? '';
        ctrls.output.text = fallback?.outputPerMTok?.toString() ?? '';
      }
    });
  }

  /// Just the input control(s) for [key] — one audio-minute field for a
  /// transcription model, or an input/output pair for a chat model.
  Widget _fields(String key) {
    final _RateRowControllers ctrls = _controllersFor(key);
    if (ctrls.isTranscription) {
      return SizedBox(
        width: 180,
        child: ConsoleField(
          controller: ctrls.audio,
          hintText: 'USD / audio min',
          fontSize: 11,
          monospace: true,
          onSubmitted: (String _) => _commit(key, ctrls),
        ),
      );
    }
    return Row(
      children: <Widget>[
        Expanded(
          child: ConsoleField(
            controller: ctrls.input,
            hintText: 'input USD / MTok',
            fontSize: 11,
            monospace: true,
            onSubmitted: (String _) => _commit(key, ctrls),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ConsoleField(
            controller: ctrls.output,
            hintText: 'output USD / MTok',
            fontSize: 11,
            monospace: true,
            onSubmitted: (String _) => _commit(key, ctrls),
          ),
        ),
      ],
    );
  }

  /// A model's own editable row: name, an optional `custom` marker plus reset,
  /// then its rate field(s).
  Widget _row(String key) {
    final _RateRowControllers ctrls = _controllersFor(key);
    final bool custom = widget.priceBook.overrides.containsKey(key);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  key,
                  style: ConsoleText.cardMeta.copyWith(color: Console.text),
                ),
              ),
              if (custom) ...<Widget>[
                Text(
                  'custom',
                  style: ConsoleText.micro.copyWith(color: Console.accent),
                ),
                TextButton(
                  onPressed: () => _reset(key, ctrls),
                  child: const Text('RESET'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          _fields(key),
        ],
      ),
    );
  }

  /// One `MISSING RATES` row: the key and its call count on one line — the
  /// only place that text renders, so it does not also duplicate the label
  /// `_row` prints for the primary list — then the same rate field(s).
  Widget _missingRow(String key, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$key  ·  $count call(s)',
            style: ConsoleText.micro.copyWith(color: Console.textSoft),
          ),
          const SizedBox(height: 6),
          _fields(key),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double storageMonthlyUsd = widget.storageBytes / 1073741824 *
        (widget.storagePrice.r2PerGbMonth + widget.storagePrice.tursoPerGbMonth);

    final List<MapEntry<String, int>> sortedMissing =
        widget.missingRateCounts.entries.toList()
          ..sort((MapEntry<String, int> a, MapEntry<String, int> b) =>
              a.key.compareTo(b.key));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHeader(title: 'PRICING'),
        const SizedBox(height: 12),
        ConsoleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              InfoRow(
                label: 'THIS MONTH',
                value: formatUsd(widget.thisMonthUsd),
              ),
              InfoRow(label: 'ALL TIME', value: formatUsd(widget.allTimeUsd)),
              InfoRow(
                label: 'STORAGE',
                value: '${formatBytes(widget.storageBytes) ?? '0 B'} ≈ '
                    '${formatUsd(storageMonthlyUsd)}/mo',
              ),
              if (widget.models.isNotEmpty) ...<Widget>[
                Divider(color: Console.border, height: 22),
                ...widget.models.map(_row),
              ],
              const SizedBox(height: 8),
              Text(
                'defaults verified '
                '${widget.verifiedOn.toIso8601String().substring(0, 10)}',
                style: ConsoleText.micro,
              ),
            ],
          ),
        ),
        if (widget.missingRateCounts.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          Text(
            'MISSING RATES',
            style: ConsoleText.chip.copyWith(
              color: Console.amber,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          ConsoleCard(
            accent: Console.amber,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final MapEntry<String, int> entry in sortedMissing)
                  _missingRow(entry.key, entry.value),
              ],
            ),
          ),
        ],
        if (widget.unknownQuantityCount > 0) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            '${widget.unknownQuantityCount} call(s) with unknown audio '
            'duration — no rate can price these',
            style: ConsoleText.micro.copyWith(color: Console.dimText),
          ),
        ],
      ],
    );
  }
}
