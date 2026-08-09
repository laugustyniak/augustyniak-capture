import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/model_price.dart';
import '../domain/price_book.dart';
import '../domain/usage_event.dart';

/// One editable row's controllers, keyed by rate key in [_PricingSectionState].
///
/// All three are always allocated — a row is either a chat shape (input +
/// output) or a transcription shape (audio-minute), never both, but keeping
/// one class rather than two subtypes means the row widget can stay a single
/// method with a branch instead of two near-duplicate ones. The focus nodes
/// exist for the same reason `RecordingEditor`'s do: a rate must commit on
/// blur as well as on Enter, or clicking to the next field silently discards
/// whatever was just typed.
class _RateRowControllers {
  _RateRowControllers({required this.isTranscription});

  final bool isTranscription;
  final TextEditingController input = TextEditingController();
  final TextEditingController output = TextEditingController();
  final TextEditingController audio = TextEditingController();
  final FocusNode inputFocus = FocusNode();
  final FocusNode outputFocus = FocusNode();
  final FocusNode audioFocus = FocusNode();

  /// The text last handed to `onRateChanged`, mirroring `RecordingEditor`'s
  /// `_syncedTitle`/`_syncedText`. Enter and blur can both fire for the same
  /// keystroke — a `TextInputAction.done` triggers `onSubmitted` and then
  /// unfocuses the field, which fires the blur listener right behind it —
  /// so a commit is skipped once the field already matches what was last
  /// sent, the same guard `_commitTitle`'s `!_titleDirty` return applies.
  String? lastCommittedInput;
  String? lastCommittedOutput;
  String? lastCommittedAudio;

  void dispose() {
    input.dispose();
    output.dispose();
    audio.dispose();
    inputFocus.dispose();
    outputFocus.dispose();
    audioFocus.dispose();
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
    required this.thisMonth,
    required this.allTime,
    required this.storageBytes,
    required this.storagePrice,
    required this.models,
    required this.priceBook,
    required this.missingRateCounts,
    required this.unknownQuantityCount,
    required this.verifiedOn,
    required this.onRateChanged,
  });

  /// See [UsageTotal]: a floor rather than a total whenever it carries any
  /// unpriced calls, and never rendered as a bare `$0.0000` when nothing in
  /// range has priced yet.
  final UsageTotal thisMonth;
  final UsageTotal allTime;
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
  /// they must never be offered this control. Each entry also says whether
  /// its calls are transcription-stage, so the row renders the field that can
  /// actually price them — see [MissingRateInfo].
  final Map<String, MissingRateInfo> missingRateCounts;
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
      // A key that already has a rate takes its shape from that rate. A key
      // with none — everything under MISSING RATES — has no rate to read the
      // shape off, so it falls back to what its own unpriced calls actually
      // are; without this a transcription-stage key always rendered the chat
      // pair (`existing` is null, so `existing?.perAudioMinute != null` is
      // always false) and a rate typed there could never price it.
      final bool isTranscription = existing != null
          ? existing.perAudioMinute != null
          : (widget.missingRateCounts[key]?.isTranscription ?? false);
      final _RateRowControllers ctrls = _RateRowControllers(
        isTranscription: isTranscription,
      );
      if (isTranscription) {
        ctrls.audio.text = existing?.perAudioMinute?.toString() ?? '';
        ctrls.lastCommittedAudio = ctrls.audio.text;
      } else {
        ctrls.input.text = existing?.inputPerMTok?.toString() ?? '';
        ctrls.output.text = existing?.outputPerMTok?.toString() ?? '';
        ctrls.lastCommittedInput = ctrls.input.text;
        ctrls.lastCommittedOutput = ctrls.output.text;
      }
      // Commit on blur as well as on Enter — `RecordingEditor`'s rule for
      // every text field in this app. `onSubmitted` alone means a rate typed
      // and then dismissed by clicking elsewhere is silently discarded.
      ctrls.inputFocus.addListener(() {
        if (!ctrls.inputFocus.hasFocus) _commit(key, ctrls);
      });
      ctrls.outputFocus.addListener(() {
        if (!ctrls.outputFocus.hasFocus) _commit(key, ctrls);
      });
      ctrls.audioFocus.addListener(() {
        if (!ctrls.audioFocus.hasFocus) _commit(key, ctrls);
      });
      return ctrls;
    });
  }

  double? _parse(String text) => double.tryParse(text.trim());

  void _commit(String key, _RateRowControllers ctrls) {
    if (ctrls.isTranscription) {
      if (ctrls.audio.text == ctrls.lastCommittedAudio) return;
      ctrls.lastCommittedAudio = ctrls.audio.text;
    } else {
      if (ctrls.input.text == ctrls.lastCommittedInput &&
          ctrls.output.text == ctrls.lastCommittedOutput) {
        return;
      }
      ctrls.lastCommittedInput = ctrls.input.text;
      ctrls.lastCommittedOutput = ctrls.output.text;
    }
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
        ctrls.lastCommittedAudio = ctrls.audio.text;
      } else {
        ctrls.input.text = fallback?.inputPerMTok?.toString() ?? '';
        ctrls.output.text = fallback?.outputPerMTok?.toString() ?? '';
        ctrls.lastCommittedInput = ctrls.input.text;
        ctrls.lastCommittedOutput = ctrls.output.text;
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
          focusNode: ctrls.audioFocus,
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
            focusNode: ctrls.inputFocus,
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
            focusNode: ctrls.outputFocus,
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
  Widget _missingRow(String key, MissingRateInfo info) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$key  ·  ${info.count} call(s)',
            style: ConsoleText.micro.copyWith(color: Console.textSoft),
          ),
          const SizedBox(height: 6),
          _fields(key),
        ],
      ),
    );
  }

  /// [InfoRow]'s text for a period total: the summed figure alone when every
  /// call in range priced, and a `+N unpriced` qualifier appended otherwise —
  /// a total is never presented as complete when it is not one. See
  /// [UsageTotal].
  String _totalLabel(UsageTotal total) {
    final int unpriced = total.unpricedCount;
    final double? amount = total.amountUsd;
    if (amount == null) {
      // Every call in range is unpriced (or there is no call in range at
      // all, in which case `unpriced` is also 0) — there is no floor to
      // show, only the qualifier when there is one, so this must never fall
      // back to `formatUsd(0)`.
      return unpriced == 0 ? formatUsd(0) : '—  ·  $unpriced unpriced';
    }
    return unpriced == 0
        ? formatUsd(amount)
        : '${formatUsd(amount)}  +$unpriced unpriced';
  }

  @override
  Widget build(BuildContext context) {
    final double storageMonthlyUsd = widget.storageBytes / 1073741824 *
        (widget.storagePrice.r2PerGbMonth + widget.storagePrice.tursoPerGbMonth);

    // The primary table is "rates in force"; MISSING RATES is "models with no
    // rate at all". The two are not naturally disjoint — `missingRateCounts`
    // only ever contains a model that also produced a usage event, which is
    // exactly what puts it in `models` too — so a model with no rate is
    // filtered out here rather than rendered twice with two copies of the
    // same `TextEditingController`s aliased into two places in the tree.
    final List<String> pricedModels = widget.models
        .where((String key) => !widget.missingRateCounts.containsKey(key))
        .toList();

    final List<MapEntry<String, MissingRateInfo>> sortedMissing =
        widget.missingRateCounts.entries.toList()
          ..sort((
            MapEntry<String, MissingRateInfo> a,
            MapEntry<String, MissingRateInfo> b,
          ) =>
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
                value: _totalLabel(widget.thisMonth),
              ),
              InfoRow(label: 'ALL TIME', value: _totalLabel(widget.allTime)),
              InfoRow(
                label: 'STORAGE',
                value: '${formatBytes(widget.storageBytes) ?? '0 B'} ≈ '
                    '${formatUsd(storageMonthlyUsd)}/mo',
              ),
              if (pricedModels.isNotEmpty) ...<Widget>[
                Divider(color: Console.border, height: 22),
                ...pricedModels.map(_row),
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
                for (final MapEntry<String, MissingRateInfo> entry
                    in sortedMissing)
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
