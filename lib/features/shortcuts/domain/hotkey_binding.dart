import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'shortcut_action.dart';

/// Modifier keys a binding can require.
///
/// Declared here rather than reusing the `hotkey_manager` enum so this layer
/// stays free of the package — the data layer does the mapping, exactly like
/// `TranscriptionService` keeps `http` out of `domain/`.
enum HotkeyModifier {
  control,
  alt,
  shift,
  meta;

  String get label => switch (this) {
        HotkeyModifier.control => 'Ctrl',
        HotkeyModifier.alt => 'Alt',
        HotkeyModifier.shift => 'Shift',
        HotkeyModifier.meta => 'Win',
      };

  static HotkeyModifier? fromName(String? name) =>
      HotkeyModifier.values.asNameMap()[name];
}

/// One key combination, stored as plain integers so it survives a JSON round
/// trip without dragging a package type into `settings.json`.
///
/// Two ids are kept on purpose:
/// - [usbHidUsage] identifies the *physical* key and is what gets registered
///   with the OS, so the hotkey keeps working after a keyboard-layout switch;
/// - [logicalKeyId] identifies the *logical* key and is only ever used to draw
///   a human-readable label ("R" rather than "0x00070015").
@immutable
class HotkeyBinding {
  const HotkeyBinding({
    required this.usbHidUsage,
    required this.logicalKeyId,
    required this.modifiers,
  });

  /// `PhysicalKeyboardKey.usbHidUsage`.
  final int usbHidUsage;

  /// `LogicalKeyboardKey.keyId`.
  final int logicalKeyId;

  final Set<HotkeyModifier> modifiers;

  factory HotkeyBinding.fromKeys({
    required PhysicalKeyboardKey physical,
    required LogicalKeyboardKey logical,
    required Set<HotkeyModifier> modifiers,
  }) {
    return HotkeyBinding(
      usbHidUsage: physical.usbHidUsage,
      logicalKeyId: logical.keyId,
      modifiers: modifiers,
    );
  }

  /// A modifier-less global hotkey would swallow a bare key system-wide — the
  /// user could no longer type that letter in any application. Never register
  /// one, and never restore one from disk.
  bool get isValid => modifiers.isNotEmpty;

  /// e.g. `Alt + Shift + R`.
  String get label => <String>[
        for (final HotkeyModifier modifier in HotkeyModifier.values)
          if (modifiers.contains(modifier)) modifier.label,
        keyLabel,
      ].join(' + ');

  String get keyLabel {
    final String? explicit = _explicitLabels[logicalKeyId];
    if (explicit != null) return explicit;

    final LogicalKeyboardKey? key =
        LogicalKeyboardKey.findKeyByKeyId(logicalKeyId);
    if (key == null) return _hex;
    final String raw = key.keyLabel.trim();
    // `debugName` is null in release builds, so this last fallback is hex. Any
    // key a user is likely to bind should be in [_explicitLabels] instead.
    if (raw.isEmpty) return key.debugName ?? _hex;
    return raw.length == 1 ? raw.toUpperCase() : raw;
  }

  String get _hex => '0x${logicalKeyId.toRadixString(16)}';

  /// Keys whose `keyLabel` is blank or unhelpful. Without these a shortcut on
  /// Space or F5 would render as `0x20`/`0x…` to anyone running a release build,
  /// where `debugName` is stripped.
  static final Map<int, String> _explicitLabels = <int, String>{
    LogicalKeyboardKey.space.keyId: 'Space',
    LogicalKeyboardKey.enter.keyId: 'Enter',
    LogicalKeyboardKey.tab.keyId: 'Tab',
    LogicalKeyboardKey.backspace.keyId: 'Backspace',
    LogicalKeyboardKey.delete.keyId: 'Delete',
    LogicalKeyboardKey.escape.keyId: 'Esc',
    LogicalKeyboardKey.insert.keyId: 'Insert',
    LogicalKeyboardKey.home.keyId: 'Home',
    LogicalKeyboardKey.end.keyId: 'End',
    LogicalKeyboardKey.pageUp.keyId: 'PgUp',
    LogicalKeyboardKey.pageDown.keyId: 'PgDn',
    LogicalKeyboardKey.arrowUp.keyId: '↑',
    LogicalKeyboardKey.arrowDown.keyId: '↓',
    LogicalKeyboardKey.arrowLeft.keyId: '←',
    LogicalKeyboardKey.arrowRight.keyId: '→',
    LogicalKeyboardKey.f1.keyId: 'F1',
    LogicalKeyboardKey.f2.keyId: 'F2',
    LogicalKeyboardKey.f3.keyId: 'F3',
    LogicalKeyboardKey.f4.keyId: 'F4',
    LogicalKeyboardKey.f5.keyId: 'F5',
    LogicalKeyboardKey.f6.keyId: 'F6',
    LogicalKeyboardKey.f7.keyId: 'F7',
    LogicalKeyboardKey.f8.keyId: 'F8',
    LogicalKeyboardKey.f9.keyId: 'F9',
    LogicalKeyboardKey.f10.keyId: 'F10',
    LogicalKeyboardKey.f11.keyId: 'F11',
    LogicalKeyboardKey.f12.keyId: 'F12',
  };

  /// Modifiers cannot be the *triggering* key of a combination — pressing Shift
  /// alone must not be captured as a binding.
  static bool isModifierKey(LogicalKeyboardKey key) =>
      _modifierKeys.contains(key);

  // `final`, not `const`: `LogicalKeyboardKey` overrides `operator ==`, and a
  // const set may only hold elements with primitive equality.
  static final Set<LogicalKeyboardKey> _modifierKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    // AltGr is the whole reason the defaults avoid Ctrl+Alt; depending on the
    // platform and layout Flutter reports it here rather than as altRight, and
    // it must never be accepted as a trigger key.
    LogicalKeyboardKey.altGraph,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.numLock,
    LogicalKeyboardKey.scrollLock,
    LogicalKeyboardKey.fn,
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'usbHidUsage': usbHidUsage,
        'logicalKeyId': logicalKeyId,
        'modifiers': modifiers
            .map((HotkeyModifier modifier) => modifier.name)
            .toList(),
      };

  /// Returns null for anything unusable — a truncated entry, or one that lost
  /// its modifiers — so a malformed `settings.json` leaves the action unbound
  /// instead of registering something dangerous.
  static HotkeyBinding? fromJson(Map<String, dynamic> json) {
    final Object? usbHidUsage = json['usbHidUsage'];
    final Object? logicalKeyId = json['logicalKeyId'];
    if (usbHidUsage is! int || logicalKeyId is! int) return null;

    final Object? rawModifiers = json['modifiers'];
    final Set<HotkeyModifier> modifiers = <HotkeyModifier>{};
    if (rawModifiers is List<dynamic>) {
      for (final Object? entry in rawModifiers) {
        final HotkeyModifier? modifier =
            HotkeyModifier.fromName(entry is String ? entry : null);
        if (modifier != null) modifiers.add(modifier);
      }
    }
    if (modifiers.isEmpty) return null;

    return HotkeyBinding(
      usbHidUsage: usbHidUsage,
      logicalKeyId: logicalKeyId,
      modifiers: modifiers,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HotkeyBinding &&
      other.usbHidUsage == usbHidUsage &&
      setEquals(other.modifiers, modifiers);

  // Deliberately excludes `logicalKeyId`: two bindings that register the same
  // physical key with the same modifiers are the same hotkey to the OS, whatever
  // letter the current layout prints on it.
  @override
  int get hashCode => Object.hash(
        usbHidUsage,
        Object.hashAllUnordered(modifiers),
      );

  @override
  String toString() => 'HotkeyBinding($label)';
}

/// First-run bindings.
class ShortcutDefaults {
  const ShortcutDefaults._();

  /// `Alt + Shift` is deliberate. Windows reports AltGr as `Ctrl + Alt`, and on
  /// the Polish programmers' layout AltGr is how you type ą/ć/ę/ł/ń/ó/ś/ź/ż — so
  /// any `Ctrl + Alt + <letter>` default would globally swallow a letter this
  /// app's own users need while writing notes.
  ///
  /// Only the three capture-critical actions ship bound. The upload shortcuts
  /// stay unbound because every plausible default (`Ctrl+Shift+V`, `Ctrl+Shift+I`)
  /// already means something in a browser or editor, and a global hotkey wins
  /// system-wide — stealing one silently is worse than leaving it to the user.
  static final Map<ShortcutAction, HotkeyBinding> bindings =
      Map<ShortcutAction, HotkeyBinding>.unmodifiable(
    <ShortcutAction, HotkeyBinding>{
      ShortcutAction.showWindow: HotkeyBinding.fromKeys(
        physical: PhysicalKeyboardKey.keyA,
        logical: LogicalKeyboardKey.keyA,
        modifiers: _altShift,
      ),
      ShortcutAction.toggleRecording: HotkeyBinding.fromKeys(
        physical: PhysicalKeyboardKey.keyR,
        logical: LogicalKeyboardKey.keyR,
        modifiers: _altShift,
      ),
      ShortcutAction.newTextNote: HotkeyBinding.fromKeys(
        physical: PhysicalKeyboardKey.keyN,
        logical: LogicalKeyboardKey.keyN,
        modifiers: _altShift,
      ),
    },
  );

  static const Set<HotkeyModifier> _altShift = <HotkeyModifier>{
    HotkeyModifier.alt,
    HotkeyModifier.shift,
  };
}
