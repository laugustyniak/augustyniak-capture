import 'r2_media_sync_service.dart';

class TursoSyncResult {
  const TursoSyncResult({required this.success, this.failureReason});

  final bool success;
  final String? failureReason;
}

class CloudSyncReport {
  const CloudSyncReport({
    required this.completedAt,
    required this.configurationFingerprint,
    this.turso,
    this.r2,
  });

  final DateTime completedAt;
  final String configurationFingerprint;
  final TursoSyncResult? turso;
  final R2SyncResult? r2;

  bool matchesConfiguration(String fingerprint) =>
      configurationFingerprint == fingerprint;

  bool get success =>
      (turso != null || r2 != null) &&
      (turso == null || turso!.success) &&
      (r2 == null || r2!.success);
  bool get partialSuccess =>
      !success && (turso?.success == true || r2?.success == true);

  String get message {
    if (turso == null && r2 == null) return 'Cloud sync is not configured.';
    final String headline = success
        ? 'Sync completed'
        : partialSuccess
        ? 'Sync partially completed'
        : 'Sync failed';
    final List<String> lines = <String>[headline];
    if (turso case final TursoSyncResult result) {
      lines.add(
        result.success
            ? 'Turso: complete'
            : 'Turso: ${result.failureReason ?? 'sync failed'}',
      );
    }
    if (r2 case final R2SyncResult result) {
      final List<String> counts = <String>[
        if (result.uploaded > 0) '${result.uploaded} uploaded',
        if (result.downloaded > 0) '${result.downloaded} downloaded',
        if (result.unchanged > 0) '${result.unchanged} unchanged',
        if (result.conflicts > 0) '${result.conflicts} conflicts',
        if (result.missing > 0) '${result.missing} missing',
      ];
      final String detail = counts.isEmpty ? 'no files' : counts.join(' · ');
      lines.add(
        result.success
            ? 'R2: $detail'
            : 'R2: ${result.failureReason ?? 'sync failed'} · $detail',
      );
    }
    return lines.join('\n');
  }
}

class CloudSyncCoordinator {
  const CloudSyncCoordinator({
    this.configurationFingerprint = '',
    this.syncTurso,
    this.syncR2,
  });

  final String configurationFingerprint;
  final Future<TursoSyncResult> Function()? syncTurso;
  final Future<R2SyncResult> Function()? syncR2;

  Future<CloudSyncReport> sync() async {
    TursoSyncResult? turso;
    R2SyncResult? r2;

    if (syncTurso != null) {
      try {
        turso = await syncTurso!();
      } catch (error) {
        turso = TursoSyncResult(
          success: false,
          failureReason: 'Turso sync failed (${error.runtimeType}).',
        );
      }
    }

    if (syncR2 != null) {
      try {
        r2 = await syncR2!();
      } catch (error) {
        r2 = R2SyncResult(
          success: false,
          failureReason: 'R2 sync failed (${error.runtimeType}).',
        );
      }
    }

    return CloudSyncReport(
      completedAt: DateTime.now(),
      configurationFingerprint: configurationFingerprint,
      turso: turso,
      r2: r2,
    );
  }
}
