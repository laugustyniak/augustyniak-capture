import 'package:augustyniak_capture/features/sync/data/supabase_sync_transport.dart';
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
}
