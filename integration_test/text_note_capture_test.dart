import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/recordings/presentation/text_note_sheet.dart';
import 'package:augustyniak_capture/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// The persist-before-process invariant, checked across the real UI, the real
/// repositories and the real file system together (#416).
///
/// Every other suite exercises one layer at a time. This one starts the whole
/// app, types a note into the compose sheet and then reads the disk directly:
/// the `.txt` must exist with bytes in it, and `recordings.json` must list the
/// note. Nothing in between is faked except where the app would otherwise land
/// — `path_provider` answers a throwaway directory and the OS keyring is an
/// in-memory map — so the run cannot reach the real library on the host.
///
/// On Linux, run it isolated from the desktop session as well:
///
///   tool/integration-test.sh integration_test/text_note_capture_test.dart
///
/// which wraps `flutter test … -d linux` in `dbus-run-session` (the
/// single-instance GtkApplication and libsecret) and `xvfb-run` (hotkeys and
/// the clipboard), with `HOME` and `XDG_*` pointed at a temp directory.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  late _LibrarySnapshot realLibrary;

  setUpAll(() async {
    // Read the real locations before replacing the provider, so the test can
    // prove afterwards that it never touched them.
    realLibrary = await _LibrarySnapshot.take(PathProviderPlatform.instance);

    sandbox = Directory.systemTemp.createTempSync('capture-e2e-');
    PathProviderPlatform.instance = _SandboxPathProvider(sandbox);
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  tearDownAll(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  testWidgets('a typed note is on disk and indexed', (
    WidgetTester tester,
  ) async {
    const String body = 'end-to-end note: persist before process';

    app.main();

    final Directory library = Directory(
      p.join(sandbox.path, 'documents', 'recordings'),
    );
    final File index = File(p.join(library.path, 'recordings.json'));
    final File log = File(p.join(library.path, 'logs.json'));

    // The capture button is live from the first frame, but addTextNote refuses
    // until the index has loaded ("Captures are still loading"). The app logs
    // the load the moment it completes and flushes the log to disk, so wait
    // for that line rather than for a span.
    await _until(
      tester,
      () =>
          log.existsSync() &&
          log.readAsStringSync().contains('captures from disk.'),
      'the index to load',
    );
    final Finder capture = find.byIcon(Icons.add_rounded).hitTestable();
    await _until(tester, () => capture.evaluate().isNotEmpty, 'capture button');

    await tester.tap(capture.first);
    final Finder newNote = find.text('New text note').hitTestable();
    await _until(tester, () => newNote.evaluate().isNotEmpty, 'capture menu');
    await _untilOpen(tester, newNote, 'capture menu');
    await tester.tap(newNote.first);

    final Finder field = find.descendant(
      of: find.byType(TextNoteSheet),
      matching: find.byType(TextField),
    );
    await _until(tester, () => field.evaluate().isNotEmpty, 'note sheet');
    // A tap aims at where the button is in this frame; while the sheet is
    // still sliding up, that is not where it is when the press lands.
    await _untilOpen(tester, field, 'note sheet');
    await tester.enterText(field, body);
    await tester.pump();
    await tester.tap(find.text('Save note'));

    await _until(
      tester,
      () => _rows(index).any((Map<String, dynamic> r) => r['type'] == 'text'),
      'the note in recordings.json',
    );

    final List<Map<String, dynamic>> rows = _rows(index);
    expect(rows, hasLength(1));
    final Map<String, dynamic> note = rows.single;
    expect(
      note['status'],
      isIn(<String>[
        'saved',
        'pendingTranscription',
        'transcribing',
        'completed',
      ]),
      reason: 'a note that reached the index must never be failed',
    );

    final File source = File(note['filePath'] as String);
    expect(
      p.isWithin(sandbox.path, source.path),
      isTrue,
      reason: 'the source must land in the sandbox, not the real library',
    );
    expect(p.extension(source.path), '.txt');
    expect(source.existsSync(), isTrue);
    expect(source.lengthSync(), greaterThan(0));
    expect(source.readAsStringSync(), body);
    expect(note['sizeBytes'], source.lengthSync());

    expect(
      await _LibrarySnapshot.take(realLibrary.provider),
      realLibrary,
      reason: 'the real recordings.json and database must be untouched',
    );
  });
}

/// Pumps frames until [condition] holds. Bounded so a capture that never lands
/// fails naming what it was waiting for, rather than hanging the run — and a
/// bound that throws cannot be mistaken for the condition it guards.
Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final Stopwatch clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > timeout) {
      // Name what was on screen too: an error banner ("still loading", a
      // failed save) is usually the whole explanation.
      final String screen = find
          .byType(Text)
          .evaluate()
          .map((Element e) => (e.widget as Text).data)
          .whereType<String>()
          .join(' | ');
      throw TestFailure(
        'Timed out after $timeout waiting for $what. On screen: $screen',
      );
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Waits for the modal route holding [inside] to finish its entrance.
Future<void> _untilOpen(WidgetTester tester, Finder inside, String what) =>
    _until(
      tester,
      () => ModalRoute.of(tester.element(inside.first))!.animation!.isCompleted,
      '$what to finish opening',
    );

List<Map<String, dynamic>> _rows(File index) {
  if (!index.existsSync()) return const <Map<String, dynamic>>[];
  // `saveAll` writes `.tmp` then renames, so a read never sees a torn file.
  final Object? decoded = jsonDecode(index.readAsStringSync());
  if (decoded is! List) return const <Map<String, dynamic>>[];
  return decoded.whereType<Map<String, dynamic>>().toList();
}

/// Every directory the app asks `path_provider` for, under one temp root.
class _SandboxPathProvider extends PathProviderPlatform {
  _SandboxPathProvider(this.root);

  final Directory root;

  Future<String> _dir(String name) async {
    final Directory dir = Directory(p.join(root.path, name));
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> getTemporaryPath() => _dir('tmp');

  @override
  Future<String?> getApplicationSupportPath() => _dir('support');

  @override
  Future<String?> getLibraryPath() => _dir('library');

  @override
  Future<String?> getApplicationDocumentsPath() => _dir('documents');

  @override
  Future<String?> getApplicationCachePath() => _dir('cache');

  @override
  Future<String?> getDownloadsPath() => _dir('downloads');
}

/// Size and modification time of the two files a capture rewrites in the real
/// library: the JSON index and the SQLite database in front of it.
class _LibrarySnapshot {
  _LibrarySnapshot(this.provider, this.files);

  final PathProviderPlatform provider;
  final Map<String, String> files;

  static Future<_LibrarySnapshot> take(PathProviderPlatform provider) async {
    final String? documents = await provider.getApplicationDocumentsPath();
    final String? support = await provider.getApplicationSupportPath();
    final List<String> paths = <String>[
      if (documents != null) p.join(documents, 'recordings', 'recordings.json'),
      if (support != null) p.join(support, 'app_database.sqlite'),
    ];
    return _LibrarySnapshot(provider, <String, String>{
      for (final String path in paths) path: _stat(File(path)),
    });
  }

  static String _stat(File file) {
    if (!file.existsSync()) return 'absent';
    final FileStat stat = file.statSync();
    return '${stat.size} bytes, modified ${stat.modified.toIso8601String()}';
  }

  @override
  bool operator ==(Object other) =>
      other is _LibrarySnapshot &&
      other.files.length == files.length &&
      files.entries.every(
        (MapEntry<String, String> e) => other.files[e.key] == e.value,
      );

  @override
  int get hashCode => Object.hashAll(files.values);

  @override
  String toString() => files.toString();
}
