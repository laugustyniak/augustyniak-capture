import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';

/// Tags as individual objects, not as one comma-separated string.
///
/// The old editor handed the user `project:acme, client, published` in a single
/// text field and split it on `,` when the sheet closed. That made the *comma*
/// part of the data model in the user's head — a tag could not contain one, a
/// stray space produced a different tag than expected, and removing the middle
/// tag of five meant editing a sentence. Here every tag is a chip with its own
/// remove button, and the field beside them adds one at a time.
///
/// Pasting `a, b, c` still works: [_commit] splits on commas, so anything
/// arriving from the old world (or from another app) lands as three chips
/// rather than one tag named "a, b, c". That is the only place the comma
/// survives, and it is an *input* convenience, never a rendering.
///
/// **There is one kind of tag.** A tag enrichment proposed and a tag typed by
/// hand are the same value, so every chip here is editable and removable. An
/// earlier model kept an owner per tag and this editor grew a second, violet,
/// un-removable row plus a "promote" gesture to move between the two — which
/// made the editor the thing the user had to understand rather than the tags.
///
/// Normalisation (trim, lowercase, de-dupe) is **not** repeated here: it lives
/// in `RecordingTags.normalize`, reached through `RecordingsController.setTags`,
/// which is the single point every write passes through. This widget only
/// avoids offering an obvious duplicate.
class TagEditor extends StatefulWidget {
  const TagEditor({
    super.key,
    required this.tags,
    required this.onChanged,
    this.suggestions = const <String>[],
  });

  /// The item's current tags, in stored order.
  final List<String> tags;

  /// Called with the complete new list on every add or remove — the caller
  /// persists immediately, so there is no "save tags" step.
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
    final List<String> next = <String>[...widget.tags];
    for (final String tag in added) {
      if (!next.any((String existing) => _same(existing, tag))) next.add(tag);
    }
    widget.onChanged(next);
    _focus.requestFocus();
  }

  void _remove(String tag) {
    widget.onChanged(
      widget.tags.where((String value) => !_same(value, tag)).toList(),
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
    if (_input.text.isNotEmpty || widget.tags.isEmpty) {
      return KeyEventResult.ignored;
    }
    _remove(widget.tags.last);
    return KeyEventResult.handled;
  }

  List<String> get _visibleSuggestions {
    final String query = _input.text.trim().toLowerCase();
    return widget.suggestions
        .where(
          (String suggestion) =>
              !widget.tags.any((String tag) => _same(tag, suggestion)) &&
              (query.isEmpty || suggestion.toLowerCase().contains(query)),
        )
        .take(_maxSuggestions)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final List<String> suggestions = _visibleSuggestions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            for (final String tag in widget.tags)
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
        if (suggestions.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
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
        color: Console.accent.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Console.accent.withValues(alpha: .2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '#$label',
            style: ConsoleText.micro.copyWith(color: Console.accent),
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
              child: Padding(
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
