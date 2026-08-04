import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/project_context_probe.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory repo;

  setUp(() async {
    repo = await Directory.systemTemp.createTemp('ctx_probe');
  });

  tearDown(() async {
    if (repo.existsSync()) await repo.delete(recursive: true);
  });

  const ProjectContextProbe probe = ProjectContextProbe(sendLimit: 100);

  Project project({String? repoPath, String? description}) => Project(
    id: 'p1',
    name: 'Augustyniak Capture',
    repoPath: repoPath ?? repo.path,
    description: description,
  );

  File file(String name) => File('${repo.path}${Platform.pathSeparator}$name');

  test('a found file reports its name and character count', () async {
    await file('CLAUDE.md').writeAsString('short brief');

    final ProjectContextStatus status = await probe.probe(project());

    expect(status.outcome, ProjectContextOutcome.file);
    expect(status.fileName, 'CLAUDE.md');
    expect(status.available, 'short brief'.length);
    expect(status.isTruncated, isFalse);
    expect(status.summary, 'CLAUDE.md · 11 chars');
    expect(status.needsAttention, isFalse);
  });

  test('a file over the ceiling says how much of it is actually sent', () async {
    await file('README.md').writeAsString('x' * 250);

    final ProjectContextStatus status = await probe.probe(project());

    expect(status.isTruncated, isTrue);
    expect(status.sent, 100);
    expect(status.available, 250);
    expect(status.summary, 'README.md · 100 of 250 chars sent');
  });

  test('no file falls back to the description', () async {
    final ProjectContextStatus status = await probe.probe(
      project(description: 'a recorder'),
    );

    expect(status.outcome, ProjectContextOutcome.description);
    expect(status.summary, 'project description · 10 chars');
    expect(status.needsAttention, isFalse);
  });

  test('neither file nor description needs attention', () async {
    final ProjectContextStatus status = await probe.probe(project());

    expect(status.outcome, ProjectContextOutcome.none);
    expect(status.summary, 'no context file, no description');
    expect(status.needsAttention, isTrue);
  });

  test('a wrong repo path is flagged even when a description exists', () async {
    // The distinction the probe exists for: at enrichment time a typo and an
    // empty repository look identical, and only one of them is fixable.
    final ProjectContextStatus status = await probe.probe(
      project(repoPath: '${repo.path}/typo', description: 'a recorder'),
    );

    expect(status.outcome, ProjectContextOutcome.repoMissing);
    expect(status.summary, 'repository path not found');
    expect(status.needsAttention, isTrue);
  });

  test('a blank repo path is not an error, just no repository', () async {
    final ProjectContextStatus status = await probe.probe(
      project(repoPath: '   ', description: 'a recorder'),
    );

    expect(status.outcome, ProjectContextOutcome.description);
    expect(status.needsAttention, isFalse);
  });
}
