import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/hotkey_binding.dart';
import '../domain/hotkey_registrar.dart';
import '../domain/shortcut_action.dart';

/// Linux implementation that talks to the `hotkey_manager_linux` platform
/// channels directly instead of going through `hotKeyManager`.
///
/// Not a stylistic preference — the package's Dart layer derives the GDK keyval
/// it hands the native side by reverse-scanning its GTK↔logical table
/// (`uni_platform`), and that scan returns the first entry that maps to the
/// logical key rather than the right one. Binding Space produced
/// `<Primary><Shift>KP_Space` — the *keypad* space — and failed outright with
/// `Binding '<Primary><Shift>KP_Space' failed!`. Going straight to the channel
/// lets us send the keyval the user actually pressed.
///
/// The native side (`hotkey_manager_linux_plugin.cc`) discards
/// `keybinder_bind`'s return value and always answers success, so a refusal can
/// never be observed. Everything this class reports as rejected is therefore
/// decided *before* the call: an unusable binding is better named up front than
/// registered into silence.
class LinuxHotkeyRegistrar implements HotkeyRegistrar {
  LinuxHotkeyRegistrar();

  static const MethodChannel _methods =
      MethodChannel('dev.leanflutter.plugins/hotkey_manager');
  static const EventChannel _events =
      EventChannel('dev.leanflutter.plugins/hotkey_manager_event');

  StreamSubscription<dynamic>? _subscription;
  ShortcutTrigger? _onTriggered;
  Map<String, ShortcutAction> _byIdentifier = <String, ShortcutAction>{};

  /// Callers must serialize their own calls — `ShortcutsCoordinator` does, via
  /// its internal queue. Two overlapping applies would interleave their
  /// `unregisterAll` with the other's registrations and leave `_byIdentifier`
  /// describing a hotkey table the OS does not have.
  @override
  Future<Set<ShortcutAction>> apply(
    Map<ShortcutAction, HotkeyBinding> bindings,
    ShortcutTrigger onTriggered,
  ) async {
    await unregisterAll();
    _onTriggered = onTriggered;
    _listen();

    final Set<ShortcutAction> rejected = <ShortcutAction>{};
    final Map<String, ShortcutAction> accepted = <String, ShortcutAction>{};

    for (final MapEntry<ShortcutAction, HotkeyBinding> entry
        in bindings.entries) {
      final HotkeyBinding binding = entry.value;
      final int? keyval = gdkKeyval(binding.logicalKeyId);
      if (!binding.isValid || binding.isUnsupportedOnLinux || keyval == null) {
        rejected.add(entry.key);
        continue;
      }

      final String identifier = entry.key.name;
      try {
        await _methods.invokeMethod<void>('register', <String, dynamic>{
          'identifier': identifier,
          'keyCode': keyval,
          'modifiers': <String>[
            for (final HotkeyModifier modifier in binding.modifiers)
              modifier.name,
          ],
        });
        accepted[identifier] = entry.key;
      } catch (_) {
        rejected.add(entry.key);
      }
    }

    _byIdentifier = accepted;
    return rejected;
  }

  @override
  Future<void> unregisterAll() async {
    // Cleared before the round trip on purpose: a press landing while the OS
    // table is being torn down has no binding left to mean, and dropping it is
    // the point — `dispose` goes through here, and the coordinator it would
    // dispatch into is on its way out.
    _byIdentifier = <String, ShortcutAction>{};
    await _subscription?.cancel();
    _subscription = null;
    await _methods.invokeMethod<void>('unregisterAll');
  }

  void _listen() {
    // Torn down and rebuilt around `unregisterAll` rather than kept for the
    // process lifetime: nothing is registered across that gap, so there is no
    // press to miss, and it means `dispose` leaves no listener behind.
    _subscription ??= _events.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is! Map) return;
        final Object? data = event['data'];
        if (event['type'] != 'onKeyDown' || data is! Map) return;
        final ShortcutAction? action = _byIdentifier[data['identifier']];
        final ShortcutTrigger? trigger = _onTriggered;
        if (action != null && trigger != null) trigger(action);
      },
      // A dead event channel must not take the app with it; the shortcuts simply
      // stop arriving, which is the same degradation as a missing keybinder.
      onError: (Object _) {},
    );
  }

  /// `LogicalKeyboardKey.keyId` → GDK keyval, which is what `gtk_accelerator_name`
  /// on the native side expects.
  ///
  /// Printable ASCII is passed through because GDK keyvals are ASCII in that
  /// range (`a` is 0x61 in both). Everything else needs the explicit table —
  /// Flutter's non-printable ids live in its own 0x100000000 plane and mean
  /// nothing to GTK. An unmapped key returns null and is reported rejected
  /// rather than registered as garbage.
  static int? gdkKeyval(int logicalKeyId) {
    if (logicalKeyId >= 0x20 && logicalKeyId < 0x7f) return logicalKeyId;
    return _gdkKeyvals[logicalKeyId];
  }

  static final Map<int, int> _gdkKeyvals = <int, int>{
    LogicalKeyboardKey.backspace.keyId: 0xff08,
    LogicalKeyboardKey.tab.keyId: 0xff09,
    LogicalKeyboardKey.enter.keyId: 0xff0d,
    LogicalKeyboardKey.escape.keyId: 0xff1b,
    LogicalKeyboardKey.home.keyId: 0xff50,
    LogicalKeyboardKey.arrowLeft.keyId: 0xff51,
    LogicalKeyboardKey.arrowUp.keyId: 0xff52,
    LogicalKeyboardKey.arrowRight.keyId: 0xff53,
    LogicalKeyboardKey.arrowDown.keyId: 0xff54,
    LogicalKeyboardKey.pageUp.keyId: 0xff55,
    LogicalKeyboardKey.pageDown.keyId: 0xff56,
    LogicalKeyboardKey.end.keyId: 0xff57,
    LogicalKeyboardKey.insert.keyId: 0xff63,
    LogicalKeyboardKey.f1.keyId: 0xffbe,
    LogicalKeyboardKey.f2.keyId: 0xffbf,
    LogicalKeyboardKey.f3.keyId: 0xffc0,
    LogicalKeyboardKey.f4.keyId: 0xffc1,
    LogicalKeyboardKey.f5.keyId: 0xffc2,
    LogicalKeyboardKey.f6.keyId: 0xffc3,
    LogicalKeyboardKey.f7.keyId: 0xffc4,
    LogicalKeyboardKey.f8.keyId: 0xffc5,
    LogicalKeyboardKey.f9.keyId: 0xffc6,
    LogicalKeyboardKey.f10.keyId: 0xffc7,
    LogicalKeyboardKey.f11.keyId: 0xffc8,
    LogicalKeyboardKey.f12.keyId: 0xffc9,
    LogicalKeyboardKey.delete.keyId: 0xffff,
  };
}
