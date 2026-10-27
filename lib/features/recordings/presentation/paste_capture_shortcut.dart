import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Creates a capture on paste outside editable text fields. An editable field
/// must keep the system paste action for its own contents.
class PasteCaptureShortcut extends StatelessWidget {
  const PasteCaptureShortcut({super.key, required this.onPaste, required this.child});

  final VoidCallback onPaste;
  final Widget child;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyV ||
        !(keyboard.isControlPressed || keyboard.isMetaPressed) ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return KeyEventResult.ignored;
    }
    onPaste();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(autofocus: true, onKeyEvent: _onKey, child: child);
}
