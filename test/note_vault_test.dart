import 'dart:io';

import 'package:augustyniak_capture/features/recordings/data/markdown_note_vault.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/note_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory vault;
  String? vaultPath;
  bool copySources = true;

  MarkdownNoteVault build() => MarkdownNoteVault(
    vaultPath: () => vaultPath,
    copySources: () => copySources,
    projectName: (String id) =>
        id == 'project-1' ? 'Augustyniak Capture' : null,
  );

  VaultNote note({
    String id = '3f9a1c2e-0000-4000-8000-000000000001',
    String title = 'Notatka o wdrożeniu',
    String body = 'Treść transkryptu.',
    String? summary,
    CaptureCategory? category = CaptureCategory.idea,
    List<String> tags = const <String>['flutter', 'obsidian'],
    CaptureType type = CaptureType.audioRecording,
    String? projectId = 'project-1',
    int durationMs = 252000,
    List<String> sourcePaths = const <String>[],
  }) => VaultNote(
    id: id,
    title: title,
    body: body,
    capturedAt: DateTime(2026, 8, 5, 14, 32, 11),
    type: type,
    summary: summary,
    category: category,
    tags: tags,
    projectId: projectId,
    durationMs: durationMs,
    sourcePaths: sourcePaths,
  );

  Directory notesDir() => Directory(p.join(vault.path, VaultDefaults.folder));

  File soleNote() {
    final List<File> files = notesDir()
        .listSync()
        .whereType<File>()
        .where((File file) => file.path.endsWith('.md'))
        .toList();
    expect(files, hasLength(1));
    return files.single;
  }

  setUp(() {
    vault = Directory.systemTemp.createTempSync('vault_test');
    vaultPath = vault.path;
    copySources = true;
  });

  tearDown(() => vault.deleteSync(recursive: true));

  test('writes one markdown file with front matter', () async {
    final VaultWrite write = await build().mirror(
      note(summary: 'Krótkie streszczenie.'),
    );

    expect(write.outcome, VaultOutcome.created);
    final File file = soleNote();
    expect(p.basename(file.path), '2026-08-05-1432-notatka-o-wdrozeniu-3f9a1c2e.md');

    final String content = file.readAsStringSync();
    expect(content, startsWith('---\n'));
    expect(content, contains('title: "Notatka o wdrożeniu"'));
    expect(content, contains('created: 2026-08-05T14:32:11.000'));
    expect(content, contains('category: idea'));
    expect(content, contains('project: "Augustyniak Capture"'));
    expect(content, contains('tags: ["flutter", "obsidian"]'));
    expect(content, contains('duration: 4m 12s'));
    expect(content, contains('capture-id: 3f9a1c2e-0000-4000-8000-000000000001'));
    expect(content, contains('# Notatka o wdrożeniu'));
    expect(content, contains('> Krótkie streszczenie.'));
    expect(content, contains('Treść transkryptu.'));
  });

  test('mirroring the same note twice writes nothing the second time', () async {
    final MarkdownNoteVault subject = build();
    await subject.mirror(note());
    final DateTime first = soleNote().lastModifiedSync();

    final VaultWrite second = await subject.mirror(note());

    expect(second.outcome, VaultOutcome.unchanged);
    expect(soleNote().lastModifiedSync(), first);
  });

  test('a changed field updates the file the title first created', () async {
    final MarkdownNoteVault subject = build();
    await subject.mirror(note(title: 'Bez tytułu'));
    final String path = soleNote().path;

    final VaultWrite update = await subject.mirror(
      note(title: 'Nazwane przez model', body: 'Poprawiony transkrypt.'),
    );

    expect(update.outcome, VaultOutcome.updated);
    // Located by id, so the rename never happens — the reader's wikilinks to
    // the old name keep resolving.
    expect(update.path, path);
    expect(soleNote().readAsStringSync(), contains('Poprawiony transkrypt.'));
    expect(soleNote().readAsStringSync(), contains('# Nazwane przez model'));
  });

  test('a note the reader edited is left alone', () async {
    final MarkdownNoteVault subject = build();
    await subject.mirror(note());
    final File file = soleNote();
    file.writeAsStringSync(
      '${file.readAsStringSync()}\nMoja własna myśl na dole.\n',
    );
    final String edited = file.readAsStringSync();

    final VaultWrite second = await subject.mirror(
      note(title: 'Nowy tytuł', body: 'Zupełnie inna treść.'),
    );

    expect(second.outcome, VaultOutcome.foreign);
    expect(file.readAsStringSync(), edited);
  });

  test('a note stripped of its front matter is foreign too', () async {
    final MarkdownNoteVault subject = build();
    await subject.mirror(note());
    final File file = soleNote();
    file.writeAsStringSync('# Przepisane od zera\n');

    expect(
      (await subject.mirror(note())).outcome,
      VaultOutcome.foreign,
    );
    expect(file.readAsStringSync(), '# Przepisane od zera\n');
  });

  test('the source file is copied and embedded', () async {
    final File source = File(p.join(vault.path, 'source.m4a'))
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);

    await build().mirror(note(sourcePaths: <String>[source.path]));

    final File copy = File(
      p.join(notesDir().path, VaultDefaults.attachments, 'source.m4a'),
    );
    expect(copy.existsSync(), isTrue);
    expect(copy.readAsBytesSync(), <int>[1, 2, 3, 4]);
    expect(
      soleNote().readAsStringSync(),
      contains('![[${VaultDefaults.attachments}/source.m4a]]'),
    );
    expect(soleNote().readAsStringSync(), contains('source: "source.m4a"'));
  });

  test('attachments can be turned off, leaving the note text-only', () async {
    copySources = false;
    final File source = File(p.join(vault.path, 'source.m4a'))
      ..writeAsBytesSync(<int>[1]);

    await build().mirror(note(sourcePaths: <String>[source.path]));

    expect(
      Directory(
        p.join(notesDir().path, VaultDefaults.attachments),
      ).existsSync(),
      isFalse,
    );
    expect(soleNote().readAsStringSync(), isNot(contains('![[')));
  });

  test('a text note never attaches its own body back to itself', () async {
    final File source = File(p.join(vault.path, 'note.txt'))
      ..writeAsStringSync('Treść.');

    await build().mirror(note(type: CaptureType.text, sourcePaths: <String>[source.path]));

    expect(soleNote().readAsStringSync(), isNot(contains('![[')));
  });

  test('no vault directory configured throws rather than writing', () async {
    vaultPath = '   ';
    final MarkdownNoteVault subject = build();

    expect(subject.isConfigured, isFalse);
    expect(
      () => subject.mirror(note()),
      throwsA(isA<VaultNotConfiguredException>()),
    );
  });

  test('a vault that is not there is named, not silently created', () async {
    vaultPath = p.join(vault.path, 'moved-away');

    expect(
      () => build().mirror(note()),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('a title that would break YAML is quoted and escaped', () async {
    await build().mirror(note(title: 'Spotkanie: "plan" \\ na jutro'));

    expect(
      soleNote().readAsStringSync(),
      contains(r'title: "Spotkanie: \"plan\" \\ na jutro"'),
    );
  });

  test('an untitled capture still gets a usable file name', () async {
    // `displayNameFor` yields "Recording · 14:32" for an un-enriched item, so
    // the slug has to survive punctuation and a middle dot.
    await build().mirror(note(title: 'Recording · 14:32'));

    expect(p.basename(soleNote().path), '2026-08-05-1432-recording-14-32-3f9a1c2e.md');
  });

  test('the folder cannot escape the vault', () async {
    final MarkdownNoteVault subject = MarkdownNoteVault(
      vaultPath: () => vault.path,
      folder: () => '/Capture',
    );

    await subject.mirror(note());

    expect(notesDir().existsSync(), isTrue);
  });

  test('every segment source is attached once', () async {
    final File audio = File(p.join(vault.parent.path, 'abc.m4a'))
      ..writeAsStringSync('audio bytes');
    final File image = File(p.join(vault.parent.path, 'abc-1.png'))
      ..writeAsStringSync('image bytes');

    final MarkdownNoteVault mirror = build();
    await mirror.mirror(note(sourcePaths: <String>[audio.path, image.path]));

    final Directory attachments = Directory(
      p.join(notesDir().path, VaultDefaults.attachments),
    );
    expect(File(p.join(attachments.path, 'abc.m4a')).existsSync(), isTrue);
    expect(File(p.join(attachments.path, 'abc-1.png')).existsSync(), isTrue);

    final String body = soleNote().readAsStringSync();
    expect(
      body.indexOf('![[${VaultDefaults.attachments}/abc.m4a]]'),
      lessThan(body.indexOf('![[${VaultDefaults.attachments}/abc-1.png]]')),
      reason: 'attachments follow segment order',
    );

    final VaultWrite again = await mirror.mirror(
      note(sourcePaths: <String>[audio.path, image.path]),
    );
    expect(
      again.outcome,
      VaultOutcome.unchanged,
      reason: 'a no-op write would bump the mtime on every pipeline tick',
    );
  });

  test('a note with no sources attaches nothing', () async {
    await build().mirror(note(type: CaptureType.text));

    expect(
      Directory(
        p.join(notesDir().path, VaultDefaults.attachments),
      ).existsSync(),
      isFalse,
      reason: 'a text segment is the body printed above, not an attachment',
    );
  });
}
