import 'hotkey_binding.dart';
import 'shortcut_action.dart';

typedef ShortcutTrigger = void Function(ShortcutAction action);

/// Swappable seam over the OS-level hotkey table, mirroring `OcrService` and
/// `VideoAudioExtractor`: the desktop implementation talks to the platform, the
/// default one does nothing so mobile builds and the pure-Dart tests never touch
/// a platform channel.
abstract class HotkeyRegistrar {
  /// Replaces the entire registration set — previous hotkeys are dropped first,
  /// so the caller never has to track what was registered last time.
  ///
  /// Returns the actions that could **not** be bound, typically because another
  /// application already owns the combination. A refusal is reported, never
  /// thrown: one unavailable combination must not cost the user the others.
  Future<Set<ShortcutAction>> apply(
    Map<ShortcutAction, HotkeyBinding> bindings,
    ShortcutTrigger onTriggered,
  );

  Future<void> unregisterAll();
}

class NoopHotkeyRegistrar implements HotkeyRegistrar {
  const NoopHotkeyRegistrar();

  @override
  Future<Set<ShortcutAction>> apply(
    Map<ShortcutAction, HotkeyBinding> bindings,
    ShortcutTrigger onTriggered,
  ) async =>
      const <ShortcutAction>{};

  @override
  Future<void> unregisterAll() async {}
}
