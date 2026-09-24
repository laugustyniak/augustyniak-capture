import 'package:augustyniak_capture/features/sync/data/supabase_sync_transport.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parsePushResult unwraps rejected rows out of their {row, code} wrapper', () {
    final result = SupabaseSyncTransport.parsePushResult(<String, Object?>{
      'applied': 1,
      'conflicts': <Object?>[
        {'id': 'p1', 'version': 2},
      ],
      'rejected': <Object?>[
        {
          'row': {'id': 'p2', 'name': 'bad'},
          'code': '23502',
        },
      ],
    });

    expect(result.applied, 1);
    expect(result.conflicts, [
      {'id': 'p1', 'version': 2},
    ]);
    // The wrapper's `code` is dropped; `rejected` carries the plain row, so
    // the engine's match-by-`rowId` finds it.
    expect(result.rejected, [
      {'id': 'p2', 'name': 'bad'},
    ]);
  });

  test('parsePushResult defaults applied, conflicts and rejected to empty when absent', () {
    final result = SupabaseSyncTransport.parsePushResult(<String, Object?>{});

    expect(result.applied, 0);
    expect(result.conflicts, isEmpty);
    expect(result.rejected, isEmpty);
  });

  test('parsePushResult ignores a malformed rejected entry rather than throwing', () {
    final result = SupabaseSyncTransport.parsePushResult(<String, Object?>{
      'applied': 0,
      'conflicts': <Object?>[],
      'rejected': <Object?>[
        'not a map',
        {'code': '22007'}, // no `row` key
      ],
    });

    expect(result.rejected, isEmpty);
  });

  test('parsePushResult throws when the rpc answers something that is not a map', () {
    expect(() => SupabaseSyncTransport.parsePushResult('unexpected'), throwsStateError);
  });

  group('keysetFilter', () {
    const String t = '2026-09-21T12:00:00.123456+00:00';

    test('a single-key table continues after (updated_at, id)', () {
      expect(
        SupabaseSyncTransport.keysetFilter(SyncTable.projects, <String, Object?>{
          'id': 'p1',
          'updated_at': t,
          'name': 'ignored',
        }),
        'updated_at.gt."$t",and(updated_at.eq."$t",id.gt."p1")',
      );
    });

    test('a composite key spells out every column lexicographically', () {
      expect(
        SupabaseSyncTransport.keysetFilter(SyncTable.revisions, <String, Object?>{
          'recording_id': 'r1',
          'at': '2026-09-21T08:00:00+00:00',
          'field': 'title',
          'updated_at': t,
        }),
        'updated_at.gt."$t",'
        'and(updated_at.eq."$t",recording_id.gt."r1"),'
        'and(updated_at.eq."$t",recording_id.eq."r1",at.gt."2026-09-21T08:00:00+00:00"),'
        'and(updated_at.eq."$t",recording_id.eq."r1",at.eq."2026-09-21T08:00:00+00:00",field.gt."title")',
      );
    });

    test('an integer key is quoted like any other value', () {
      expect(
        SupabaseSyncTransport.keysetFilter(SyncTable.segments, <String, Object?>{
          'recording_id': 'r1',
          'index': 3,
          'updated_at': t,
        }),
        endsWith('recording_id.eq."r1",index.gt."3")'),
      );
    });

    test('reserved characters stay inside the quotes', () {
      final String filter = SupabaseSyncTransport.keysetFilter(SyncTable.projects, <String, Object?>{
        'id': r'a,b)c"d\e',
        'updated_at': t,
      });
      expect(filter, endsWith(r'id.gt."a,b)c\"d\\e")'));
    });
  });
}

