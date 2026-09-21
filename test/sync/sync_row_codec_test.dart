import 'package:augustyniak_capture/features/clipboard/domain/clipboard_item.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:flutter_test/flutter_test.dart';

Recording _recording({
  String? title,
  String? transcript,
  List<CaptureSegment>? segments,
}) => Recording(
  id: 'rec-1',
  filePath: '/tmp/rec-1.m4a',
  createdAt: DateTime.utc(2026, 9, 21, 8),
  durationMs: 1200,
  status: RecordingStatus.completed,
  type: CaptureType.audioRecording,
  title: title,
  transcript: transcript,
  category: CaptureCategory.idea,
  tags: const <String>['a', 'b'],
  segments: segments,
);

void main() {
  test('recording row uses server column names and only the file name', () {
    final Map<String, Object?> row = SyncRowCodec.recording(_recording(title: 'T'));
    expect(row['id'], 'rec-1');
    expect(row['file_path'], 'rec-1.m4a');
    expect(row['created_at'], '2026-09-21T08:00:00.000Z');
    expect(row['tags'], <String>['a', 'b']);
    expect(row['category'], 'idea');
    expect(row.containsKey('owner_id'), isFalse);
    expect(row.containsKey('updated_at'), isFalse);
  });

  test('hash ignores version and deleted_at and key order', () {
    final Map<String, Object?> a = <String, Object?>{'id': 'x', 'title': 't', 'version': 1};
    final Map<String, Object?> b = <String, Object?>{'title': 't', 'id': 'x', 'version': 9, 'deleted_at': null};
    expect(SyncRowCodec.hash(a), SyncRowCodec.hash(b));
    expect(SyncRowCodec.hash(a), isNot(SyncRowCodec.hash(<String, Object?>{'id': 'x', 'title': 'u'})));
  });

  test('recording round-trips through a server row', () {
    final Recording original = _recording(title: 'T', transcript: 'hello');
    final Map<String, Object?> row = SyncRowCodec.recording(original)
      ..['version'] = 4
      ..['updated_at'] = '2026-09-21T09:00:00Z'
      ..['deleted_at'] = null;
    final Recording? back = SyncRowCodec.recordingFromRow(row, local: original);
    expect(back, isNotNull);
    expect(back!.toJson()..remove('filePath'), original.toJson()..remove('filePath'));
    expect(back.filePath, original.filePath, reason: 'local path is kept when present');
  });

  test('a recording row missing its id decodes to null, not a throw', () {
    expect(SyncRowCodec.recordingFromRow(<String, Object?>{'title': 'x'}), isNull);
  });

  test('composite row ids join key columns with /', () {
    final RecordingRevision revision = RecordingRevision(
      recordingId: 'rec-1', at: DateTime.utc(2026, 1, 1), field: 'title',
      from: 'a', to: 'b', source: RevisionSource.user,
    );
    final Map<String, Object?> row = SyncRowCodec.revision(revision);
    expect(SyncRowCodec.rowId(SyncTable.revisions, row),
        'rec-1/2026-01-01T00:00:00.000Z/title');
    expect(row['from_value'], 'a');
    expect(row['to_value'], 'b');
  });

  test('table names and keys match the schema', () {
    expect(SyncTable.clipboardItems.serverName, 'clipboard_items');
    expect(SyncTable.segments.keyColumns, <String>['recording_id', 'index']);
    expect(SyncTable.syncState.keyColumns, <String>['device_id', 'table_name']);
  });

  test('a revision row missing a required field decodes to null, not a throw', () {
    expect(
      SyncRowCodec.revisionFromRow(<String, Object?>{'recording_id': 'rec-1'}),
      isNull,
    );
  });

  test('a revision row with non-string optional fields degrades instead of throwing', () {
    final RecordingRevision? back = SyncRowCodec.revisionFromRow(<String, Object?>{
      'recording_id': 'rec-1',
      'at': '2026-01-01T00:00:00Z',
      'field': 'title',
      'from_value': 42,
      'to_value': 'b',
      'source': 7,
    });
    expect(back, isNotNull);
    expect(back!.from, isNull, reason: 'a non-string from_value drops to null, not a cast throw');
    expect(back.to, 'b');
    expect(back.source, RevisionSource.processor, reason: 'a non-string source degrades to the fromName default');
  });

  test('project round-trips through a server row', () {
    final Project original = Project(
      id: 'proj-1',
      name: 'Capture',
      repoPath: '/home/me/capture',
      description: 'notes app',
      sessionName: 'main',
      defaultAgent: AgentKind.codex,
      commandHost: 'fleet-1',
      commandWorkspace: 'ws-1',
      commandBoundAt: DateTime.utc(2026, 2, 1),
    );
    final Map<String, Object?> row = SyncRowCodec.project(original)
      ..['version'] = 2
      ..['updated_at'] = '2026-09-21T09:00:00Z'
      ..['deleted_at'] = null;
    final Project? back = SyncRowCodec.projectFromRow(row);
    expect(back, isNotNull);
    expect(back!.toJson(), original.toJson());
  });

  test('a project row missing its id decodes to null, not a throw', () {
    expect(SyncRowCodec.projectFromRow(<String, Object?>{'name': 'x'}), isNull);
  });

  test('clipboard item round-trips through a server row', () {
    final ClipboardItem original = ClipboardItem(
      id: 'clip-1',
      type: ClipboardItemType.text,
      copiedAt: DateTime.utc(2026, 3, 1, 12),
      text: 'hello world',
      preview: 'hello world',
      collections: const <String>{'a', 'b'},
    );
    final Map<String, Object?> row = SyncRowCodec.clipboardItem(original)
      ..['version'] = 3
      ..['updated_at'] = '2026-09-21T09:00:00Z'
      ..['deleted_at'] = null;
    final ClipboardItem? back = SyncRowCodec.clipboardItemFromRow(row);
    expect(back, isNotNull);
    expect(back, original);
  });

  test('a clipboard row missing its id decodes to null, not a throw', () {
    expect(SyncRowCodec.clipboardItemFromRow(<String, Object?>{'text': 'x'}), isNull);
  });

  test('segments() produces one row per stored segment, recording_id set', () {
    final Recording withSegments = _recording(
      segments: <CaptureSegment>[
        CaptureSegment(
          index: 0,
          filePath: '/tmp/rec-1.m4a',
          type: CaptureType.audioRecording,
          createdAt: DateTime.utc(2026, 9, 21, 8),
          durationMs: 1200,
          sizeBytes: 100,
          text: 'hello',
        ),
        CaptureSegment(
          index: 1,
          filePath: '/tmp/rec-1-1.jpg',
          type: CaptureType.image,
          createdAt: DateTime.utc(2026, 9, 21, 9),
          sizeBytes: 200,
        ),
      ],
    );
    final List<Map<String, Object?>> rows = SyncRowCodec.segments(withSegments);
    expect(rows.length, 2);
    expect(rows[0]['recording_id'], 'rec-1');
    expect(rows[0]['index'], 0);
    expect(rows[0]['file_path'], 'rec-1.m4a');
    expect(rows[1]['index'], 1);
    expect(rows[1]['file_path'], 'rec-1-1.jpg');
  });

  test('segments() is empty for a recording with no stored fragments', () {
    expect(SyncRowCodec.segments(_recording()), isEmpty);
  });

  test('segments() normalizes a local-time segment timestamp to UTC', () {
    final Recording withLocalTime = _recording(
      segments: <CaptureSegment>[
        CaptureSegment(
          index: 0,
          filePath: '/tmp/rec-1.m4a',
          type: CaptureType.audioRecording,
          createdAt: DateTime(2026, 9, 21, 8),
        ),
      ],
    );
    final List<Map<String, Object?>> rows = SyncRowCodec.segments(withLocalTime);
    expect(
      (rows.single['created_at'] as String).endsWith('Z'),
      isTrue,
      reason: 'a timestamptz column must never receive an offsetless local string',
    );
  });
}
