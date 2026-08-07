import 'dart:io';

import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/agent_artifact_scanner.dart';
import 'package:augustyniak_capture/features/recordings/domain/agent_artifact.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/harness.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('agent_feedback_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('AgentArtifact Domain Model', () {
    test('toJson and fromJson serialize correctly', () {
      final now = DateTime.now();
      final artifact = AgentArtifact(
        id: 'test-path.md',
        captureId: 'cap-123',
        title: 'Deep Research Results',
        path: '/path/to/test-path.md',
        updatedAt: now,
        kind: AgentArtifactKind.resultNote,
        snippet: 'Here are the research findings...',
      );

      final json = artifact.toJson();
      final deserialized = AgentArtifact.fromJson(json);

      expect(deserialized, isNotNull);
      expect(deserialized!.id, 'test-path.md');
      expect(deserialized.captureId, 'cap-123');
      expect(deserialized.title, 'Deep Research Results');
      expect(deserialized.path, '/path/to/test-path.md');
      expect(deserialized.kind, AgentArtifactKind.resultNote);
      expect(deserialized.snippet, 'Here are the research findings...');
    });
  });

  group('Recording with artifacts', () {
    test('Recording preserves artifacts across json roundtrip', () {
      final artifact = AgentArtifact(
        id: 'res-1',
        captureId: 'rec-1',
        title: 'Result Note',
        path: '/tmp/res.md',
        updatedAt: DateTime.parse('2026-08-05T12:00:00Z'),
        kind: AgentArtifactKind.resultNote,
      );

      final recording = Recording(
        id: 'rec-1',
        filePath: '/tmp/rec.m4a',
        createdAt: DateTime.parse('2026-08-05T10:00:00Z'),
        durationMs: 5000,
        status: RecordingStatus.completed,
        artifacts: <AgentArtifact>[artifact],
      );

      final json = recording.toJson();
      final restored = Recording.fromJson(json);

      expect(restored.artifacts.length, 1);
      expect(restored.artifacts.first.title, 'Result Note');
      expect(restored.artifacts.first.path, '/tmp/res.md');
    });
  });

  group('AgentArtifactScanner', () {
    test('scans .agent-tasks/<id>-result.md in project repository', () async {
      final projectDir = Directory(p.join(tempDir.path, 'my-project'));
      final agentTasksDir = Directory(p.join(projectDir.path, '.agent-tasks'));
      await agentTasksDir.create(recursive: true);

      final captureId = 'cap-abc';
      final resultFile = File(p.join(agentTasksDir.path, '$captureId-result.md'));
      await resultFile.writeAsString('''# Deep Research Findings

Summary of deep research on architectural options.
''');

      final project = Project(
        id: 'proj-1',
        name: 'My Project',
        repoPath: projectDir.path,
      );

      final recording = Recording(
        id: captureId,
        filePath: p.join(tempDir.path, '$captureId.txt'),
        createdAt: DateTime.now(),
        durationMs: 0,
        type: CaptureType.text,
        status: RecordingStatus.completed,
        projectId: project.id,
      );

      const scanner = AgentArtifactScanner();
      final artifacts = await scanner.scanForCapture(
        recording: recording,
        project: project,
      );

      expect(artifacts.length, 1);
      expect(artifacts.first.title, 'Deep Research Findings');
      expect(artifacts.first.kind, AgentArtifactKind.resultNote);
      expect(artifacts.first.snippet, contains('Summary of deep research'));
    });

    test('scans repository markdown notes with capture-id in frontmatter', () async {
      final projectDir = Directory(p.join(tempDir.path, 'my-project'));
      await projectDir.create(recursive: true);

      final captureId = 'cap-xyz';
      final connectedNote = File(p.join(projectDir.path, 'research-notes.md'));
      await connectedNote.writeAsString('''---
capture-id: cap-xyz
title: Connected Analysis
---

# Connected Analysis

Notes linked to capture-xyz.
''');

      final project = Project(
        id: 'proj-2',
        name: 'My Project 2',
        repoPath: projectDir.path,
      );

      final recording = Recording(
        id: captureId,
        filePath: p.join(tempDir.path, '$captureId.txt'),
        createdAt: DateTime.now(),
        durationMs: 0,
        type: CaptureType.text,
        status: RecordingStatus.completed,
        projectId: project.id,
      );

      const scanner = AgentArtifactScanner();
      final artifacts = await scanner.scanForCapture(
        recording: recording,
        project: project,
      );

      expect(artifacts.length, 1);
      expect(artifacts.first.title, 'Connected Analysis');
      expect(artifacts.first.kind, AgentArtifactKind.connectedNote);
    });
  });

  group('RecordingsController Artifact Integration', () {
    test('refreshArtifacts and attachArtifact update recording state', () async {
      final projectDir = Directory(p.join(tempDir.path, 'my-proj'));
      final agentTasksDir = Directory(p.join(projectDir.path, '.agent-tasks'));
      await agentTasksDir.create(recursive: true);

      final project = Project(
        id: 'proj-100',
        name: 'Test Proj',
        repoPath: projectDir.path,
      );

      final captureId = 'cap-555';
      final recording = Recording(
        id: captureId,
        filePath: p.join(tempDir.path, '$captureId.txt'),
        createdAt: DateTime.now(),
        durationMs: 0,
        type: CaptureType.text,
        status: RecordingStatus.completed,
        projectId: project.id,
      );

      final repo = FakeRecordingsRepository(tempDir, seed: <Recording>[recording]);

      final controller = RecordingsController(
        repository: repo,
        transcriptionService: const DisabledTranscriptionService(),
        projectById: (id) => id == project.id ? project : null,
        player: FakePlayer(),
        recorder: FakeRecorder(),
      );
      await controller.initialize();

      // Initially no artifacts
      expect(controller.recordings.first.artifacts, isEmpty);

      // Create a result file
      final resultFile = File(p.join(agentTasksDir.path, '$captureId-result.md'));
      await resultFile.writeAsString('# Agent Output\nFinished task.');

      final refreshed = await controller.refreshArtifacts(captureId);
      expect(refreshed.length, 1);
      expect(refreshed.first.title, 'Agent Output');
      expect(controller.recordings.first.artifacts.length, 1);

      // Manually attach another file
      final extraFile = File(p.join(tempDir.path, 'custom_note.md'));
      await extraFile.writeAsString('# Custom Note');

      await controller.attachArtifact(captureId, extraFile.path);
      expect(controller.recordings.first.artifacts.length, 2);
    });
  });
}
