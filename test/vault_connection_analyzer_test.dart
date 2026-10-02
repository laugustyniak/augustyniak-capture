import 'dart:io';

import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/recordings/data/markdown_note_vault.dart';
import 'package:augustyniak_capture/features/recordings/data/vault_connection_analyzer.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/connection_reasoner.dart';
import 'package:augustyniak_capture/features/recordings/domain/note_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory vault;
  const String id = '3f9a1c2e-0000-4000-8000-000000000001';
  final VaultNote note = VaultNote(
    id: id,
    title: 'Import notatek Obsidian',
    body: 'Import notatek Obsidian z aplikacji Capture i linkowanie projektów.',
    capturedAt: DateTime(2026, 10, 3),
    type: CaptureType.text,
  );

  setUp(() => vault = Directory.systemTemp.createTempSync('connections_'));
  tearDown(() => vault.deleteSync(recursive: true));

  Future<String> source() async {
    final VaultWrite write = await MarkdownNoteVault(
      vaultPath: () => vault.path,
    ).mirror(note);
    return write.path!;
  }

  test(
    'links an existing related note and keeps an unrelated note out',
    () async {
      final String sourcePath = await source();
      final Directory projects = Directory(p.join(vault.path, 'Projects'))
        ..createSync();
      File(p.join(projects.path, 'Knowledge.md')).writeAsStringSync(
        '# Obsidian import\n\nProjekt importu notatek i linkowanie w Obsidian.\n',
      );
      File(
        p.join(projects.path, 'Lunch.md'),
      ).writeAsStringSync('# Lunch\n\nPlan obiadu na jutro.\n');

      final artifact = await const VaultConnectionAnalyzer().analyze(
        vault: vault,
        note: note,
        sourcePath: sourcePath,
        reasoner: const ReviewConnectionReasoner(),
        context: EnrichmentContext.none,
      );

      final String analysis = File(artifact.path).readAsStringSync();
      expect(analysis, contains('[[Projects/Knowledge]]'));
      expect(analysis, contains('shared terms:'));
      expect(analysis, isNot(contains('Lunch')));
      expect(analysis, contains('Decision: clarify'));
      expect(analysis, contains('[[Capture/'));
    },
  );

  test('rerun is idempotent and never overwrites a user edit', () async {
    final String sourcePath = await source();
    final VaultConnectionAnalyzer analyzer = const VaultConnectionAnalyzer();
    Future<String> run() async => (await analyzer.analyze(
      vault: vault,
      note: note,
      sourcePath: sourcePath,
      reasoner: const ReviewConnectionReasoner(),
      context: EnrichmentContext.none,
    )).path;

    final File output = File(await run());
    expect(output.readAsStringSync(), contains('No related notes found'));
    final DateTime firstModified = output.lastModifiedSync();
    await run();
    expect(output.lastModifiedSync(), firstModified);

    output.writeAsStringSync('${output.readAsStringSync()}\nMy own comment.\n');
    await run();
    expect(output.readAsStringSync(), contains('My own comment.'));
  });
}
