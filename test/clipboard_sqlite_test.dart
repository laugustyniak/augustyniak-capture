import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/features/clipboard/data/sqlite_clipboard_repository.dart';
import 'package:augustyniak_capture/features/clipboard/domain/clipboard_item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// An image entry owns a PNG on disk, and it is the only file this feature
/// writes. Nothing sweeps the images directory — unlike `recordings/`, where
/// `findOrphans` re-adopts a source with no row — so a row removed without its
/// file leaves a stray that no code path can ever name again.
///
/// All three ways a row leaves therefore have to take the file with it. Two of
/// them always did; **eviction did not**, because it was a bare
/// `DELETE ... WHERE id NOT IN (...)` that dropped the only record of where the
/// file was before anything could read it.
void main() {
  late Directory dir;
  late Database db;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('clipboard-sqlite-');
    AppDatabase.resetForTesting();
    db = sqlite3.openInMemory();
    await AppDatabase.getInstance(overrideDb: db);
  });

  tearDown(() {
    AppDatabase.resetForTesting();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A real file, because "was it deleted" is the whole assertion.
  File imageFile(String name) =>
      File(p.join(dir.path, name))..writeAsBytesSync(<int>[1, 2, 3]);

  ClipboardItem image(String id, String path, int minute) => ClipboardItem(
    id: id,
    type: ClipboardItemType.image,
    imagePath: path,
    // Explicit and increasing: the cap is applied by `copied_at DESC`, so a
    // shared timestamp would make which row falls off the end arbitrary.
    copiedAt: DateTime.utc(2026, 8, 9, 12, minute),
  );

  ClipboardItem text(String id, String body, int minute) => ClipboardItem(
    id: id,
    type: ClipboardItemType.text,
    text: body,
    copiedAt: DateTime.utc(2026, 8, 9, 12, minute),
  );

  test('eviction past the cap deletes the PNG the dropped row owned', () async {
    final SqliteClipboardRepository repository = SqliteClipboardRepository(
      maxItems: 2,
    );
    final File png = imageFile('evicted.png');

    await repository.addItem(image('image-1', png.path, 1));
    await repository.addItem(text('t1', 'one', 2));
    // Still inside the cap: this is what separates "eviction deletes it" from
    // "something deletes it eventually".
    expect(await png.exists(), isTrue);

    await repository.addItem(text('t2', 'two', 3));

    expect(
      repository.items.map((ClipboardItem item) => item.id),
      <String>['t2', 't1'],
    );
    expect(await png.exists(), isFalse);
  });

  test('deleting one entry takes its PNG', () async {
    final SqliteClipboardRepository repository = SqliteClipboardRepository();
    final File png = imageFile('deleted.png');
    await repository.addItem(image('image-1', png.path, 1));

    await repository.deleteItem('image-1');

    expect(repository.items, isEmpty);
    expect(await png.exists(), isFalse);
  });

  test('clearing the history takes every PNG', () async {
    final SqliteClipboardRepository repository = SqliteClipboardRepository();
    final File first = imageFile('a.png');
    final File second = imageFile('b.png');
    await repository.addItem(image('image-1', first.path, 1));
    await repository.addItem(image('image-2', second.path, 2));

    await repository.clearHistory();

    expect(repository.items, isEmpty);
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isFalse);
  });

  test('a PNG that is already gone does not fail the operation', () async {
    // Best-effort by contract: the history operation the user asked for must
    // not fail because a file somebody else removed is missing.
    final SqliteClipboardRepository repository = SqliteClipboardRepository();
    await repository.addItem(
      image('image-1', p.join(dir.path, 'never-written.png'), 1),
    );

    await repository.deleteItem('image-1');

    expect(repository.items, isEmpty);
  });
}
