import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes_phase1/features/settings/data/settings_repository.dart';
import 'package:voice_notes_phase1/features/settings/domain/app_settings.dart';
import 'package:voice_notes_phase1/features/settings/presentation/settings_controller.dart';
import 'package:voice_notes_phase1/features/shortcuts/domain/hotkey_binding.dart';
import 'package:voice_notes_phase1/features/shortcuts/domain/shortcut_action.dart';

/// Keeps `settings.json` in memory — no path_provider, no disk.
class _FakeSettingsRepository extends SettingsRepository {
  AppSettings? stored;

  @override
  Future<AppSettings?> load() async => stored;

  @override
  Future<void> save(AppSettings settings) async {
    stored = settings;
  }
}

HotkeyBinding _binding(
  PhysicalKeyboardKey physical,
  LogicalKeyboardKey logical, {
  Set<HotkeyModifier> modifiers = const <HotkeyModifier>{
    HotkeyModifier.alt,
    HotkeyModifier.shift,
  },
}) =>
    HotkeyBinding.fromKeys(
      physical: physical,
      logical: logical,
      modifiers: modifiers,
    );

void main() {
  group('HotkeyBinding', () {
    test('round-trips through JSON', () {
      final HotkeyBinding binding = _binding(
        PhysicalKeyboardKey.keyR,
        LogicalKeyboardKey.keyR,
        modifiers: const <HotkeyModifier>{
          HotkeyModifier.control,
          HotkeyModifier.shift,
        },
      );

      final HotkeyBinding? restored = HotkeyBinding.fromJson(
        jsonDecode(jsonEncode(binding.toJson())) as Map<String, dynamic>,
      );

      expect(restored, binding);
      expect(restored!.label, 'Ctrl + Shift + R');
    });

    test('label lists modifiers in a stable order regardless of set order', () {
      final HotkeyBinding a = _binding(
        PhysicalKeyboardKey.keyN,
        LogicalKeyboardKey.keyN,
        modifiers: const <HotkeyModifier>{
          HotkeyModifier.shift,
          HotkeyModifier.control,
          HotkeyModifier.alt,
        },
      );
      expect(a.label, 'Ctrl + Alt + Shift + N');
    });

    test('a binding without modifiers is invalid and never restored', () {
      final HotkeyBinding bare = _binding(
        PhysicalKeyboardKey.keyR,
        LogicalKeyboardKey.keyR,
        modifiers: const <HotkeyModifier>{},
      );
      expect(bare.isValid, isFalse);

      // A modifier-less hotkey would swallow the bare key system-wide, so it
      // must not survive a load even if it somehow reached the file.
      expect(HotkeyBinding.fromJson(bare.toJson()), isNull);
    });

    test('a truncated entry loads as unbound rather than throwing', () {
      expect(
        HotkeyBinding.fromJson(<String, dynamic>{'modifiers': <String>['alt']}),
        isNull,
      );
    });

    test('equality ignores the logical key — the OS sees the physical one', () {
      // Same physical key, labelled differently by two keyboard layouts.
      final HotkeyBinding qwerty = HotkeyBinding(
        usbHidUsage: PhysicalKeyboardKey.keyY.usbHidUsage,
        logicalKeyId: LogicalKeyboardKey.keyY.keyId,
        modifiers: const <HotkeyModifier>{HotkeyModifier.alt},
      );
      final HotkeyBinding qwertz = HotkeyBinding(
        usbHidUsage: PhysicalKeyboardKey.keyY.usbHidUsage,
        logicalKeyId: LogicalKeyboardKey.keyZ.keyId,
        modifiers: const <HotkeyModifier>{HotkeyModifier.alt},
      );

      expect(qwerty, qwertz);
      expect(qwerty.hashCode, qwertz.hashCode);
    });

    test('modifier keys cannot themselves trigger a combination', () {
      expect(HotkeyBinding.isModifierKey(LogicalKeyboardKey.shiftLeft), isTrue);
      expect(HotkeyBinding.isModifierKey(LogicalKeyboardKey.altRight), isTrue);
      expect(HotkeyBinding.isModifierKey(LogicalKeyboardKey.keyR), isFalse);
    });
  });

  group('AppSettings.shortcuts', () {
    test('legacy JSON without a shortcuts key falls back to the defaults', () {
      final AppSettings settings = AppSettings.fromJson(<String, dynamic>{
        'profiles': <dynamic>[],
        'activeProfileId': null,
      });

      expect(settings.hasCustomShortcuts, isFalse);
      expect(settings.shortcuts, ShortcutDefaults.bindings);
      expect(settings.shortcuts[ShortcutAction.toggleRecording]?.label,
          'Alt + Shift + R');
      // Untouched defaults are not written back, so a later build can still ship
      // a default for an action that does not exist yet.
      expect(settings.toJson().containsKey('shortcuts'), isFalse);
    });

    test('a stored map is authoritative — a cleared shortcut stays cleared', () {
      final AppSettings edited = AppSettings.empty.copyWith(
        shortcuts: <ShortcutAction, HotkeyBinding>{
          ShortcutAction.showWindow:
              _binding(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA),
        },
      );

      final AppSettings restored = AppSettings.fromJson(
        jsonDecode(jsonEncode(edited.toJson())) as Map<String, dynamic>,
      );

      expect(restored.hasCustomShortcuts, isTrue);
      expect(restored.shortcuts.keys, <ShortcutAction>[ShortcutAction.showWindow]);
      expect(restored.shortcuts[ShortcutAction.toggleRecording], isNull);
    });

    test('an empty stored map means every shortcut is off', () {
      final AppSettings none = AppSettings.empty
          .copyWith(shortcuts: <ShortcutAction, HotkeyBinding>{});
      final AppSettings restored = AppSettings.fromJson(
        jsonDecode(jsonEncode(none.toJson())) as Map<String, dynamic>,
      );

      expect(restored.hasCustomShortcuts, isTrue);
      expect(restored.shortcuts, isEmpty);
    });

    test('an unknown action name is dropped, the rest survives', () {
      final AppSettings restored = AppSettings.fromJson(<String, dynamic>{
        'shortcuts': <String, dynamic>{
          'summonTheKraken': <String, dynamic>{
            'usbHidUsage': 1,
            'logicalKeyId': 1,
            'modifiers': <String>['alt'],
          },
          'showWindow':
              _binding(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA)
                  .toJson(),
        },
      });

      expect(restored.shortcuts.keys, <ShortcutAction>[ShortcutAction.showWindow]);
    });
  });

  group('SettingsController shortcuts', () {
    late _FakeSettingsRepository repository;
    late SettingsController controller;

    setUp(() async {
      repository = _FakeSettingsRepository();
      controller = SettingsController(repository: repository);
      await controller.initialize();
    });

    tearDown(() => controller.dispose());

    test('setShortcut persists the whole resolved map', () async {
      final HotkeyBinding binding = _binding(
        PhysicalKeyboardKey.keyK,
        LogicalKeyboardKey.keyK,
        modifiers: const <HotkeyModifier>{HotkeyModifier.control},
      );

      await controller.setShortcut(ShortcutAction.uploadImage, binding);

      expect(controller.settings.shortcuts[ShortcutAction.uploadImage], binding);
      // The defaults it started from are now written down too, not implied.
      expect(repository.stored!.hasCustomShortcuts, isTrue);
      expect(repository.stored!.shortcuts[ShortcutAction.toggleRecording],
          isNotNull);
    });

    test('binding a combination takes it away from the action that had it',
        () async {
      final HotkeyBinding recordDefault =
          controller.settings.shortcuts[ShortcutAction.toggleRecording]!;

      await controller.setShortcut(ShortcutAction.uploadVideo, recordDefault);

      expect(controller.settings.shortcuts[ShortcutAction.uploadVideo],
          recordDefault);
      // Two registrations of one combination would let the OS pick a winner.
      expect(controller.settings.shortcuts[ShortcutAction.toggleRecording],
          isNull);
    });

    test('a modifier-less binding is refused outright', () async {
      await controller.setShortcut(
        ShortcutAction.showWindow,
        _binding(
          PhysicalKeyboardKey.keyA,
          LogicalKeyboardKey.keyA,
          modifiers: const <HotkeyModifier>{},
        ),
      );

      expect(controller.settings.hasCustomShortcuts, isFalse);
    });

    test('clearShortcut survives a reload, resetShortcuts brings defaults back',
        () async {
      await controller.clearShortcut(ShortcutAction.toggleRecording);

      final SettingsController reloaded =
          SettingsController(repository: repository);
      await reloaded.initialize();
      expect(reloaded.settings.shortcuts[ShortcutAction.toggleRecording], isNull);
      reloaded.dispose();

      await controller.resetShortcuts();
      expect(controller.settings.hasCustomShortcuts, isFalse);
      expect(controller.settings.shortcuts, ShortcutDefaults.bindings);
    });
  });
}
