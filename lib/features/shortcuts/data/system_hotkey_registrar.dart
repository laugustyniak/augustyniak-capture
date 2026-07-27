import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import '../domain/hotkey_binding.dart';
import '../domain/hotkey_registrar.dart';
import '../domain/shortcut_action.dart';

/// Desktop implementation: system-scoped hotkeys through `hotkey_manager`
/// (`RegisterHotKey` on Windows, the X11/Carbon equivalents elsewhere).
///
/// Registers the *physical* key, so a hotkey bound on a QWERTY layout keeps
/// firing on the same physical key after the user switches layouts.
class SystemHotkeyRegistrar implements HotkeyRegistrar {
  const SystemHotkeyRegistrar();

  @override
  Future<Set<ShortcutAction>> apply(
    Map<ShortcutAction, HotkeyBinding> bindings,
    ShortcutTrigger onTriggered,
  ) async {
    // Wholesale replacement: the OS keeps every registration until it is told
    // otherwise, so re-applying without clearing would leave the old
    // combination live alongside the new one.
    await unregisterAll();

    final Set<ShortcutAction> rejected = <ShortcutAction>{};
    for (final MapEntry<ShortcutAction, HotkeyBinding> entry
        in bindings.entries) {
      final HotkeyBinding binding = entry.value;
      if (!binding.isValid) {
        rejected.add(entry.key);
        continue;
      }

      try {
        await hotKeyManager.register(
          HotKey(
            key: PhysicalKeyboardKey(binding.usbHidUsage),
            modifiers: binding.modifiers.map(_toHotKeyModifier).toList(),
            scope: HotKeyScope.system,
          ),
          keyDownHandler: (HotKey _) => onTriggered(entry.key),
        );
      } catch (_) {
        // The OS refuses a combination another application already owns. Collect
        // it and keep going — the remaining hotkeys must still bind.
        rejected.add(entry.key);
      }
    }
    return rejected;
  }

  @override
  Future<void> unregisterAll() => hotKeyManager.unregisterAll();

  static HotKeyModifier _toHotKeyModifier(HotkeyModifier modifier) =>
      switch (modifier) {
        HotkeyModifier.control => HotKeyModifier.control,
        HotkeyModifier.alt => HotKeyModifier.alt,
        HotkeyModifier.shift => HotKeyModifier.shift,
        HotkeyModifier.meta => HotKeyModifier.meta,
      };
}
