import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/hotkey_binding.dart';
import '../domain/shortcut_action.dart';

/// Config-tab block for the global hotkeys. Desktop only — the shell decides
/// whether to render it, the same way it decides which OCR service to build.
class ShortcutsSection extends StatelessWidget {
  const ShortcutsSection({
    super.key,
    required this.controller,
    required this.rejected,
    required this.runWithHotkeysSuspended,
  });

  final SettingsController controller;

  /// Actions the OS refused to bind, reported back by the registrar.
  final Set<ShortcutAction> rejected;

  /// Runs [action] with every global registration released. Supplied by the
  /// shell, which owns the coordinator; see [_capture] for why it is needed.
  final Future<void> Function(Future<void> Function() action)
  runWithHotkeysSuspended;

  @override
  Widget build(BuildContext context) {
    final Map<ShortcutAction, HotkeyBinding> bindings =
        controller.settings.shortcuts;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHeader(title: 'GLOBAL SHORTCUTS'),
        const SizedBox(height: 12),
        ConsoleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final ShortcutAction action
                  in ShortcutAction.values) ...<Widget>[
                _ShortcutRow(
                  action: action,
                  binding: bindings[action],
                  isRejected: rejected.contains(action),
                  onCapture: () => _capture(context, action),
                  onClear: bindings[action] == null
                      ? null
                      : () => controller.clearShortcut(action),
                ),
                if (action != ShortcutAction.values.last)
                  Divider(color: Console.border, height: 18),
              ],
              const SizedBox(height: 12),
              Text(
                'Shortcuts work system-wide, even when the window is '
                'minimised. Recording raises the window only after the capture '
                'has started, so the microphone is never kept waiting; '
                'stopping does not raise it at all. On Linux a Shift '
                'combination with a letter, digit or symbol does not work — '
                'Shift changes which key the system listens for. Shift with '
                'F1–F12, space or Enter is safe.',
                style: TextStyle(
                  color: Console.mutedSoft,
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: controller.settings.hasCustomShortcuts
                      ? controller.resetShortcuts
                      : null,
                  icon: const Icon(Icons.restart_alt, size: 17),
                  label: const Text('RESTORE DEFAULTS'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// A system-scope hotkey is consumed by the OS *before* the focused window
  /// sees the event, so with the registrations live the user could never rebind
  /// a combination that is already bound — pressing Alt+Shift+R to change it
  /// would start a recording instead. Everything is released for the lifetime
  /// of the sheet and re-registered (with the new binding) on close.
  Future<void> _capture(BuildContext context, ShortcutAction action) {
    return runWithHotkeysSuspended(() async {
      final HotkeyBinding? binding = await showModalBottomSheet<HotkeyBinding>(
        context: context,
        builder: (BuildContext context) => ConsolePaletteScope(
          builder: (BuildContext context) =>
              _HotkeyCaptureSheet(action: action),
        ),
      );
      if (binding != null) {
        await controller.setShortcut(action, binding);
      }
    });
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    required this.action,
    required this.binding,
    required this.isRejected,
    required this.onCapture,
    required this.onClear,
  });

  final ShortcutAction action;
  final HotkeyBinding? binding;
  final bool isRejected;
  final VoidCallback onCapture;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final HotkeyBinding? current = binding;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                action.label,
                style: TextStyle(
                  color: Console.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (isRejected) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  'This combination will not work — taken by another app, '
                  'or unsupported on this system. Pick another.',
                  style: TextStyle(color: Console.amber, fontSize: 9.5),
                ),
              ],
            ],
          ),
        ),
        _BindingChip(binding: current, isRejected: isRejected),
        IconButton(
          onPressed: onCapture,
          icon: const Icon(Icons.edit_outlined, size: 17),
          color: Console.accent,
          tooltip: 'Change shortcut',
        ),
        IconButton(
          onPressed: onClear,
          icon: const Icon(Icons.backspace_outlined, size: 16),
          color: Console.muted,
          tooltip: 'Clear shortcut',
        ),
      ],
    );
  }
}

class _BindingChip extends StatelessWidget {
  const _BindingChip({required this.binding, required this.isRejected});

  final HotkeyBinding? binding;
  final bool isRejected;

  @override
  Widget build(BuildContext context) {
    final HotkeyBinding? current = binding;
    final Color color = current == null
        ? Console.muted
        : (isRejected ? Console.amber : Console.accent);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Console.surfaceRaised,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: current == null ? Console.border : color),
      ),
      child: Text(
        current?.label ?? 'none',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

/// Grabs the next key combination the user presses.
///
/// Swallows every key while open (including Tab and Enter) — that is the point:
/// the sheet is a raw capture surface, and letting focus traversal through would
/// make Tab unbindable.
class _HotkeyCaptureSheet extends StatefulWidget {
  const _HotkeyCaptureSheet({required this.action});

  final ShortcutAction action;

  @override
  State<_HotkeyCaptureSheet> createState() => _HotkeyCaptureSheetState();
}

class _HotkeyCaptureSheetState extends State<_HotkeyCaptureSheet> {
  HotkeyBinding? _captured;
  String? _hint;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    // Releasing a modifier changes what the live preview should show.
    if (event is KeyUpEvent) {
      if (HotkeyBinding.isModifierKey(event.logicalKey)) setState(() {});
      return KeyEventResult.handled;
    }
    // Auto-repeat carries no new information here.
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    final LogicalKeyboardKey logical = event.logicalKey;
    if (logical == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }

    // A modifier press only refreshes the live preview; it can never be the
    // triggering key of a combination.
    if (HotkeyBinding.isModifierKey(logical)) {
      setState(() {});
      return KeyEventResult.handled;
    }

    final Set<HotkeyModifier> modifiers = _pressedModifiers();
    if (modifiers.isEmpty) {
      setState(() {
        _hint =
            'A global shortcut needs a modifier — otherwise it would '
            'swallow this key system-wide.';
      });
      return KeyEventResult.handled;
    }

    setState(() {
      _hint = null;
      _captured = HotkeyBinding.fromKeys(
        physical: event.physicalKey,
        logical: logical,
        modifiers: modifiers,
      );
    });
    return KeyEventResult.handled;
  }

  static Set<HotkeyModifier> _pressedModifiers() {
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    return <HotkeyModifier>{
      if (keyboard.isControlPressed) HotkeyModifier.control,
      if (keyboard.isAltPressed) HotkeyModifier.alt,
      if (keyboard.isShiftPressed) HotkeyModifier.shift,
      if (keyboard.isMetaPressed) HotkeyModifier.meta,
    };
  }

  /// What to show before a full combination lands: the modifiers currently held.
  String get _preview {
    final HotkeyBinding? captured = _captured;
    if (captured != null) return captured.label;

    final Set<HotkeyModifier> held = _pressedModifiers();
    if (held.isEmpty) return 'Press a combination…';
    return <String>[
      for (final HotkeyModifier modifier in HotkeyModifier.values)
        if (held.contains(modifier)) modifier.label,
      '…',
    ].join(' + ');
  }

  @override
  Widget build(BuildContext context) {
    final HotkeyBinding? captured = _captured;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                widget.action.label,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Escape cancels.',
                style: TextStyle(color: Console.mutedSoft, fontSize: 10),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 22),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Console.surfaceRaised,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: captured == null ? Console.border : Console.accent,
                  ),
                ),
                child: Text(
                  _preview,
                  style: TextStyle(
                    color: captured == null ? Console.muted : Console.accent,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              if (_hint != null) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  _hint!,
                  style: TextStyle(
                    color: Console.amber,
                    fontSize: 10,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: captured == null
                      ? null
                      : () => Navigator.pop(context, captured),
                  style: FilledButton.styleFrom(
                    backgroundColor: Console.accent,
                    foregroundColor: Console.ink,
                    disabledBackgroundColor: Console.surfaceRaised,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Save shortcut'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
