import 'package:augustyniak_capture/core/sync/cloud_sync_coordinator.dart';
import 'package:augustyniak_capture/core/sync/r2_media_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs Turso before R2 and reports both provider results', () async {
    final List<String> order = <String>[];
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncTurso: () async {
        order.add('turso');
        return const TursoSyncResult(success: true);
      },
      syncR2: () async {
        order.add('r2');
        return const R2SyncResult(success: true, uploaded: 2, downloaded: 1);
      },
    ).sync();

    expect(order, <String>['turso', 'r2']);
    expect(report.success, isTrue);
    expect(report.message, contains('Turso: complete'));
    expect(report.message, contains('R2: 2 uploaded · 1 downloaded'));
  });

  test('keeps R2 success visible when Turso fails', () async {
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncTurso: () async => const TursoSyncResult(
        success: false,
        failureReason: 'Turso rejected the auth token (HTTP 403).',
      ),
      syncR2: () async => const R2SyncResult(success: true, unchanged: 4),
    ).sync();

    expect(report.success, isFalse);
    expect(report.partialSuccess, isTrue);
    expect(report.message, contains('Sync partially completed'));
    expect(report.message, contains('Turso rejected the auth token'));
    expect(report.message, contains('R2: 4 unchanged'));
  });

  test('runs the only configured provider', () async {
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncR2: () async => const R2SyncResult(success: true, uploaded: 1),
    ).sync();

    expect(report.turso, isNull);
    expect(report.r2?.uploaded, 1);
    expect(report.message, isNot(contains('Turso')));
  });

  test('reports that cloud sync is not configured', () async {
    final CloudSyncReport report = await const CloudSyncCoordinator().sync();

    expect(report.success, isFalse);
    expect(report.message, 'Cloud sync is not configured.');
  });

  test('still runs R2 and reports safely when Turso throws', () async {
    bool r2Ran = false;
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncTurso: () => throw StateError('secret response body'),
      syncR2: () async {
        r2Ran = true;
        return const R2SyncResult(success: true, unchanged: 2);
      },
    ).sync();

    expect(r2Ran, isTrue);
    expect(report.partialSuccess, isTrue);
    expect(report.turso?.failureReason, 'Turso sync failed (StateError).');
    expect(report.message, isNot(contains('secret response body')));
  });

  test('keeps the Turso result when R2 throws', () async {
    final CloudSyncReport report = await CloudSyncCoordinator(
      syncTurso: () async => const TursoSyncResult(success: true),
      syncR2: () => throw ArgumentError('secret key'),
    ).sync();

    expect(report.partialSuccess, isTrue);
    expect(report.r2?.failureReason, 'R2 sync failed (ArgumentError).');
    expect(report.message, isNot(contains('secret key')));
  });
}
