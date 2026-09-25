import 'package:augustyniak_capture/core/sync/cloud_sync_coordinator.dart';
import 'package:augustyniak_capture/features/sync/domain/media_sync.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
