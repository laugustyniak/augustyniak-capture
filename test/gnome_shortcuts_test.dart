import 'dart:io';

import 'package:augustyniak_capture/features/shortcuts/domain/shortcut_action.dart';
import 'package:augustyniak_capture/features/shortcuts/domain/hotkey_binding.dart';
import 'package:augustyniak_capture/features/shortcuts/domain/shortcut_link.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `tool/gnome-shortcuts.sh` against a fake `gsettings` that keeps its state in
/// files, so the keybinding list and every relocatable key can be inspected
/// without touching the developer's real dconf database (#381).
void main() {
  late Directory temp;
  late Directory state;

  const String listKey = 'org.gnome.settings-daemon.plugins.media-keys';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('gnome_shortcuts_');
    state = Directory('${temp.path}/state')..createSync();
    final Directory fakeBin = Directory('${temp.path}/fakebin')..createSync();
    // Keys are stored one file per schema+key, the schema path flattened.
    final File gsettings = File('${fakeBin.path}/gsettings')
      ..writeAsStringSync(r'''#!/usr/bin/env bash
cmd="$1"; schema="$2"; key="$3"
file="$GSETTINGS_STATE/$(printf '%s__%s' "$schema" "$key" | tr '/:' '__')"
case "$cmd" in
  get)
    if [ -f "$file" ]; then cat "$file"; else echo "@as []"; fi ;;
  set)
    printf '%s\n' "$4" > "$file" ;;
  *) echo "unsupported $cmd" >&2; exit 1 ;;
esac
''');
    Process.runSync('chmod', <String>['+x', gsettings.path]);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<ProcessResult> run() => Process.run(
    'bash',
    <String>['tool/gnome-shortcuts.sh'],
    environment: <String, String>{
      'PATH': '${temp.path}/fakebin:${Platform.environment['PATH']}',
      'GSETTINGS_STATE': state.path,
    },
  );

  File keyFile(String schema, String key) => File(
    '${state.path}/${'${schema}__$key'.replaceAll('/', '_').replaceAll(':', '_')}',
  );

  String list() =>
      keyFile(listKey, 'custom-keybindings').readAsStringSync().trim();

  String entry(ShortcutAction action, String key) => keyFile(
    '$listKey.custom-keybinding:'
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/'
    'ai-augustyniak-capture-${action.name}/',
    key,
  ).readAsStringSync().trim();

  /// The defaults that have a binding, as the script must install them.
  Map<ShortcutAction, String> expected() {
    final Map<ShortcutAction, String> out = <ShortcutAction, String>{};
    ShortcutDefaults.bindings.forEach((ShortcutAction action, binding) {
      final String key = LogicalKeyboardKey(
        binding.logicalKeyId,
      ).keyLabel.toLowerCase();
      out[action] = '<Control><Alt>$key';
    });
    return out;
  }

  test('installs one GNOME keybinding per default shortcut', () async {
    final ProcessResult r = await run();
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');

    final Map<ShortcutAction, String> want = expected();
    expect(want.keys, hasLength(4));
    for (final MapEntry<ShortcutAction, String> e in want.entries) {
      expect(entry(e.key, 'binding'), e.value, reason: e.key.name);
      expect(
        entry(e.key, 'command'),
        'xdg-open ${ShortcutLink.forAction(e.key)}',
        reason: e.key.name,
      );
      expect(entry(e.key, 'name'), contains(e.key.name));
      expect(list(), contains('ai-augustyniak-capture-${e.key.name}/'));
    }
  });

  test('running twice leaves one entry per action', () async {
    expect((await run()).exitCode, 0);
    final String first = list();
    expect((await run()).exitCode, 0);

    expect(list(), first);
    for (final ShortcutAction action in expected().keys) {
      expect(
        RegExp('ai-augustyniak-capture-${action.name}/').allMatches(list()),
        hasLength(1),
        reason: action.name,
      );
    }
  });

  test("leaves the user's other custom keybindings alone", () async {
    keyFile(listKey, 'custom-keybindings').writeAsStringSync(
      "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']\n",
    );

    expect((await run()).exitCode, 0);

    expect(
      list(),
      startsWith(
        "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/', ",
      ),
    );
    expect(RegExp('ai-augustyniak-capture-').allMatches(list()), hasLength(4));
  });
}
