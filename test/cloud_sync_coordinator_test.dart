import 'package:augustyniak_capture/core/sync/cloud_sync_coordinator.dart';
import 'package:augustyniak_capture/features/sync/domain/media_sync.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reports real stages and outcomes in order', () async {
    final List<CloudSyncProgress> progress = <CloudSyncProgress>[];
    await CloudSyncCoordinator(
      syncSupabase: () async => const SupabaseSyncResult(pushed: 2),
      syncMedia: () async => const MediaSyncResult(downloaded: 1),
    ).sync(onProgress: progress.add);

    expect(progress.map((CloudSyncProgress p) => p.stage), <CloudSyncStage>[
      CloudSyncStage.metadata,
      CloudSyncStage.storage,
      CloudSyncStage.complete,
    ]);
    expect(progress[1].supabase?.pushed, 2);
    expect(progress[2].media?.downloaded, 1);
  });

  test('skips unconfigured stages without claiming they ran', () async {
    final List<CloudSyncProgress> progress = <CloudSyncProgress>[];
    await const CloudSyncCoordinator().sync(onProgress: progress.add);

    expect(progress.map((CloudSyncProgress p) => p.stage), <CloudSyncStage>[
      CloudSyncStage.complete,
    ]);
    expect(progress.single.supabase, isNull);
    expect(progress.single.media, isNull);
  });

  test('storage runs after the supabase metadata slot and reports its counts', () async {
    final List<String> order = <String>[];
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncSupabase: () async {
        order.add('supabase');
        return const SupabaseSyncResult(pulled: 1);
      },
      syncMedia: () async {
        order.add('media');
        return const MediaSyncResult(downloaded: 1, waiting: 2);
      },
    ).sync();

    expect(order, <String>['supabase', 'media']);
    expect(report.success, isTrue);
    expect(report.message, contains('Storage: 1 downloaded · 2 waiting'));
  });

  test('a storage throw is caught and fails the report without its message', () async {
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncMedia: () => throw StateError('signed url'),
    ).sync();

    expect(report.success, isFalse);
    expect(report.media?.failureReason, 'Storage sync failed (StateError).');
    expect(report.message, isNot(contains('signed url')));
  });

  test('supabase result reports its counts', () async {
    final CloudSyncCoordinator c = CloudSyncCoordinator(
      syncSupabase: () async => const SupabaseSyncResult(pushed: 2, pulled: 1),
    );
    final CloudSyncReport report = await c.sync();
    expect(report.success, isTrue);
    expect(report.message, contains('Supabase: 2 pushed · 1 pulled'));
  });

  test('a supabase failure makes the report fail with its reason', () async {
    final CloudSyncCoordinator c = CloudSyncCoordinator(
      syncSupabase: () async => const SupabaseSyncResult(failureReason: 'offline'),
    );
    final CloudSyncReport report = await c.sync();
    expect(report.success, isFalse);
    expect(report.message, contains('Supabase: offline'));
  });

  test('a supabase throw is caught and reported without leaking its message', () async {
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncSupabase: () => throw StateError('secret token'),
    ).sync();

    expect(report.success, isFalse);
    expect(report.supabase?.failureReason, 'Supabase sync failed (StateError).');
    expect(report.message, isNot(contains('secret token')));
  });

  test('supabase counts render conflicts, removed and skipped when present', () async {
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncSupabase: () async => const SupabaseSyncResult(
        pushed: 1,
        pulled: 2,
        conflicts: 3,
        tombstonesApplied: 4,
        skipped: 5,
      ),
    ).sync();

    expect(
      report.message,
      contains(
        'Supabase: 1 pushed · 2 pulled · 3 conflicts · 4 removed · 5 skipped',
      ),
    );
  });

  test('item conflicts explain the resolution and separate sync bookkeeping', () async {
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncSupabase: () async => const SupabaseSyncResult(
        conflicts: 2,
        conflictDetails: <SyncConflictDetail>[
          SyncConflictDetail(
            table: 'recordings',
            id: 'capture-1',
            resolution: SyncConflictResolution.serverApplied,
            overwrittenFields: <String>['title'],
          ),
          SyncConflictDetail(
            table: 'sync_state',
            id: 'device-1/recordings',
            resolution: SyncConflictResolution.serverAdopted,
          ),
        ],
      ),
    ).sync();

    expect(report.success, isTrue);
    expect(report.hasItemConflicts, isTrue);
    expect(report.message, startsWith('Sync completed with conflicts'));
    expect(report.message, contains('1 item conflict · 1 sync state conflict'));
    expect(report.message, contains('Recording capture-1: server version applied; previous title in HISTORY'));
    expect(report.message, isNot(contains('device-1/recordings')));
  });

  test('a later failure keeps earlier conflict details visible', () async {
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncSupabase: () async => const SupabaseSyncResult(
        conflicts: 1,
        failureReason: 'network unavailable',
        conflictDetails: <SyncConflictDetail>[
          SyncConflictDetail(
            table: 'recordings',
            id: 'capture-1',
            resolution: SyncConflictResolution.serverApplied,
          ),
        ],
      ),
    ).sync();

    expect(report.success, isFalse);
    expect(report.message, contains('Before failure: 1 item conflict'));
    expect(report.message, contains('Recording capture-1: server version applied'));
  });

  test('bookkeeping conflicts do not mark item data as conflicted', () async {
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncSupabase: () async => const SupabaseSyncResult(
        conflicts: 1,
        conflictDetails: <SyncConflictDetail>[
          SyncConflictDetail(
            table: 'devices',
            id: 'device-1',
            resolution: SyncConflictResolution.serverAdopted,
          ),
        ],
      ),
    ).sync();

    expect(report.hasItemConflicts, isFalse);
    expect(report.message, startsWith('Sync completed\n'));
    expect(report.message, contains('1 sync state conflict'));
  });

  test('keeps storage success visible when supabase fails', () async {
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncSupabase: () async =>
          const SupabaseSyncResult(failureReason: 'offline'),
      syncMedia: () async => const MediaSyncResult(unchanged: 4),
    ).sync();

    expect(report.success, isFalse);
    expect(report.partialSuccess, isTrue);
    expect(report.message, contains('Sync partially completed'));
    expect(report.message, contains('Supabase: offline'));
    expect(report.message, contains('Storage: 4 unchanged'));
  });

  test('reports that cloud sync is not configured', () async {
    final CloudSyncReport report = await const CloudSyncCoordinator().sync();

    expect(report.success, isFalse);
    expect(report.message, 'Cloud sync is not configured.');
  });
}
