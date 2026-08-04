import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../domain/recording_tag.dart';

/// Tags as individual objects, not as one comma-separated string.
///
/// The old editor handed the user `project:acme, client, published` in a single
/// text field and split it on `,` when the sheet closed. That made the *comma*
/// part of the data model in the user's head — a tag could not contain one, a
/// stray space produced a different tag than expected, and removing the middle
/// tag of five meant editing a sentence. Here every tag is a chip with its own
/// remove button, and the field below adds one at a time.
///
/// Pasting `a, b, c` still works: [_commit] splits on commas, so anything
/// arriving from the old world (or from another app) lands as three chips
/// rather than one tag named "a, b, c". That is the only place the comma
/// survives, and it is an *input* convenience, never a rendering.
///
/// Human tags are editable and cyan. AI tags are violet suggestions; tapping
/// one promotes it to human, where it can then be changed without a future
/// enrichment retry overwriting it.
class TagEditor extends StatefulWidget {
  const TagEditor({
    super.key,
    required this.tags,
    required this.onChanged,
    this.suggestions = const <String>[],
  });

  final List<RecordingTag> tags;

  /// Called with the complete new human list on every edit or promotion.
  final ValueChanged<List<String>> onChanged;

  /// Tags already used on *other* captures. Offered as one-tap chips so a
  /// vocabulary stays a vocabulary instead of fragmenting into `acme`,
  /// `Acme` and `acme-corp`.
  final List<String> suggestions;

  @override
  State<TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<TagEditor> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// Enough to be useful, few enough to stay one or two lines on a card.
  static const int _maxSuggestions = 6;

  static const String promoteHint = 'Tap a suggestion to keep it as your own';

  List<String> get _human => widget.tags
      .where((RecordingTag tag) => tag.source == RecordingTagSource.human)
      .map((RecordingTag tag) => tag.value)
      .toList();

  List<String> get _ai => widget.tags
      .where((RecordingTag tag) => tag.source == RecordingTagSource.ai)
      .map((RecordingTag tag) => tag.value)
      .toList();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Turns whatever is in the field into tags and hands the new list up. Keeps
  /// focus so a run of tags can be typed without reaching for the mouse.
  void _commit([String? raw]) {
    final String source = raw ?? _input.text;
    final List<String> added = source
        .split(',')
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toList();
    _input.clear();
    if (added.isEmpty) {
      setState(() {}); // the suggestion filter reads the field
      return;
    }
    final List<String> next = <String>[..._human];
    for (final String tag in added) {
      if (!next.any((String existing) => _same(existing, tag))) next.add(tag);
    }
    widget.onChanged(next);
    _focus.requestFocus();
  }

  void _remove(String tag) {
    widget.onChanged(
      _human.where((String value) => !_same(value, tag)).toList(),
    );
  }

  /// Case-insensitive because `setTags` lowercases anyway — comparing raw would
  /// let `Acme` in next to `acme` and then silently collapse them on save.
  static bool _same(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();

  /// Backspace on an empty field removes the last chip — the convention every
  /// tag input follows. Soft keyboards do not reliably deliver a key event for
  /// backspace on an empty field, so this is an accelerator, never the only way
  /// to remove a tag; each chip carries its own × for that reason.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    final List<String> human = _human;
    if (_input.text.isNotEmpty || human.isEmpty) {
      return KeyEventResult.ignored;
    }
    _remove(human.last);
    return KeyEventResult.handled;
  }

  List<String> get _visibleSuggestions {
    final String query = _input.text.trim().toLowerCase();
    final List<String> assigned = <String>[..._human, ..._ai];
    return widget.suggestions
        .where(
          (String suggestion) =>
              !assigned.any((String tag) => _same(tag, suggestion)) &&
              (query.isEmpty || suggestion.toLowerCase().contains(query)),
        )
        .take(_maxSuggestions)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final List<String> suggestions = _visibleSuggestions;
    final List<String> ai = _ai;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            for (final String tag in _human)
              _TagChip(label: tag, onRemove: () => _remove(tag)),
            // Sized rather than Expanded: it is a Wrap child, so it has to
            // carry its own width or it would claim a whole run to itself.
            SizedBox(
              width: 148,
              child: Focus(
                onKeyEvent: _onKey,
                child: ConsoleField(
                  controller: _input,
                  focusNode: _focus,
                  hintText: '+ add tag',
                  monospace: true,
                  fontSize: 11.5,
                  textInputAction: TextInputAction.done,
                  onSubmitted: _commit,
                  // A pasted or typed comma commits on the spot, so the field
                  // never accumulates a list — that was the old behaviour.
                  onChanged: (String value) {
                    if (value.contains(',')) {
                      _commit();
                    } else {
                      setState(() {}); // re-filter the suggestions
                    }
                  },
                ),
              ),
            ),
          ],
        ),
        if (ai.isNotEmpty) ...<Widget>[
          const SizedBox(height: 9),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.only(top: 5),
                child: Icon(
                  Icons.auto_awesome,
                  size: 11,
                  color: Console.violet,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final String tag in ai)
                      _AiTagChip(label: tag, onPromote: () => _commit(tag)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            promoteHint,
            style: ConsoleText.micro.copyWith(color: Console.dim),
          ),
        ],
        if (suggestions.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.only(top: 5),
                child: Text('USED', style: ConsoleText.micro),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final String suggestion in suggestions)
                      _SuggestionChip(
                        label: suggestion,
                        onTap: () => _commit(suggestion),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// An assigned tag: the same pill the read-only card draws, plus the one
/// control that makes this an editor rather than a display.
class _TagChip extends StatelessWidget {
  const _TagChip({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 4, 4, 4),
      decoration: BoxDecoration(
        color: Console.cyan.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Console.cyan.withValues(alpha: .2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '#$label',
            style: ConsoleText.micro.copyWith(color: Console.cyan),
          ),
          const SizedBox(width: 4),
          // Semantics outside, gesture inside: the label is the node a caller
          // finds, and the action it announces is the one thing under it.
          Semantics(
            button: true,
            label: 'Remove tag $label',
            child: InkResponse(
              onTap: onRemove,
              radius: 14,
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(
                  Icons.close_rounded,
                  size: 12,
                  color: Console.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiTagChip extends StatelessWidget {
  const _AiTagChip({required this.label, required this.onPromote});

  final String label;
  final VoidCallback onPromote;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Keep AI tag $label as your own',
      child: InkWell(
        onTap: onPromote,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: Console.violet.withValues(alpha: .07),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Console.violet.withValues(alpha: .22)),
          ),
          child: Text(
            '#$label',
            style: ConsoleText.micro.copyWith(color: Console.violet),
          ),
        ),
      ),
    );
  }
}

/// A tag borrowed from another capture. Dimmer than an assigned one and without
/// a remove control, so the two rows never read as the same thing.
class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Add tag $label',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Console.border),
          ),
          child: Text(
            '#$label',
            style: ConsoleText.micro.copyWith(color: Console.muted),
          ),
        ),
      ),
    );
  }
}
