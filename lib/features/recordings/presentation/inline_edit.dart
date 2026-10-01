import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';

/// A field of the open capture that turns into a text field when clicked.
///
/// The same rule as [RecordingEditor]: nothing is staged. Losing focus — a
/// click elsewhere, Tab, or Enter on a single-line field — writes through
/// [onCommit]; Escape puts the stored value back and leaves without writing.
/// An unchanged value is never written, so clicking in and out costs nothing.
class InlineEditText extends StatefulWidget {
  InlineEditText({
    super.key,
    required this.value,
    required this.display,
    required this.onCommit,
    required this.semanticLabel,
    this.hintText,
    this.multiline = false,
    this.fontSize = 15,
    this.allowEmpty = true,
  });

  /// The stored value — what the field opens with and reverts to.
  final String value;

  /// What is drawn while not editing.
  final Widget display;
  final ValueChanged<String> onCommit;
  final String semanticLabel;
  final String? hintText;
  final bool multiline;
  final double fontSize;

  /// False for the transcript: `editTranscript` refuses a blank edit, so a
  /// cleared field is put back and the refusal is said out loud.
  final bool allowEmpty;

  @override
  State<InlineEditText> createState() => _InlineEditTextState();
}

class _InlineEditTextState extends State<InlineEditText> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _editing = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    _input.text = widget.value;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _focus.requestFocus();
    });
  }

  void _commit() {
    if (!_editing) return;
    final String next = _input.text.trim();
    setState(() => _editing = false);
    if (next == widget.value.trim()) return;
    if (next.isEmpty && !widget.allowEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: const Text(
            'Captures cannot be empty. Use delete to remove the capture.',
          ),
          backgroundColor: Console.amber,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }
    widget.onCommit(next);
  }

  void _cancel() {
    _input.text = widget.value;
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return TapRegion(
        onTapOutside: (_) => _focus.unfocus(),
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): _cancel,
          },
          child: ConsoleField(
            controller: _input,
            focusNode: _focus,
            fontSize: widget.fontSize,
            hintText: widget.hintText,
            minLines: widget.multiline ? 3 : 1,
            maxLines: widget.multiline ? null : 1,
            textInputAction: widget.multiline
                ? TextInputAction.newline
                : TextInputAction.done,
            onSubmitted: widget.multiline ? null : (_) => _focus.unfocus(),
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _start,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            // Negative margin keeps the text where it was; the padding is only
            // there so the hover wash does not touch the glyphs.
            transform: Matrix4.translationValues(-6, -4, 0),
            decoration: BoxDecoration(
              color: _hovered ? Console.surfaceRaised : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: widget.display,
          ),
        ),
      ),
    );
  }
}

/// The tag row of the open capture: chips until clicked, then [TagEditor]'s
/// chips-and-input until a click lands outside it. Each add or remove already
/// writes through `setTags`, so leaving only changes the mode.
class InlineEditTags extends StatefulWidget {
  InlineEditTags({super.key, required this.display, required this.editor});

  final Widget display;
  final Widget editor;

  static const String semanticLabel = 'Edit tags';

  @override
  State<InlineEditTags> createState() => _InlineEditTagsState();
}

class _InlineEditTagsState extends State<InlineEditTags> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return TapRegion(
        onTapOutside: (_) => setState(() => _editing = false),
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                setState(() => _editing = false),
          },
          child: widget.editor,
        ),
      );
    }
    return Semantics(
      button: true,
      label: InlineEditTags.semanticLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _editing = true),
          child: widget.display,
        ),
      ),
    );
  }
}
