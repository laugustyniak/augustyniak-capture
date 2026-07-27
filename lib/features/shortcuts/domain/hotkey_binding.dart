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

  static HotkeyModifier? fromName(String? name) {
    for (final HotkeyModifier modifier in HotkeyModifier.values) {
      if (modifier.name == name) return modifier;
    }
    return null;
  }
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
    final LogicalKeyboardKey? key =
        LogicalKeyboardKey.findKeyByKeyId(logicalKeyId);
    if (key == null) return '0x${logicalKeyId.toRadixString(16)}';
    // Space and the other whitespace keys have a blank `keyLabel`; `debugName`
    // is the only readable fallback and is itself null in release builds.
    final String raw = key.keyLabel.trim();
    if (raw.isEmpty) return key.debugName ?? '0x${logicalKeyId.toRadixString(16)}';
    return raw.length == 1 ? raw.toUpperCase() : raw;
  }

  /// Modifiers cannot be the *triggering* key of a combination — pressing Shift
  /// alone must not be captured as a binding.
  static bool isModifierKey(LogicalKeyboardKey key) =>
      _modifierKeys.contains(key);

  static final Set<LogicalKeyboardKey> _modifierKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
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
