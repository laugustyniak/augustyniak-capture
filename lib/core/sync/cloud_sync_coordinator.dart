import '../../features/sync/domain/sync_snapshot.dart';
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
    this.supabase,
    this.r2,
  });

  final DateTime completedAt;
  final String configurationFingerprint;
  final TursoSyncResult? turso;
  final SupabaseSyncResult? supabase;
  final R2SyncResult? r2;

  bool matchesConfiguration(String fingerprint) =>
      configurationFingerprint == fingerprint;

  bool get success =>
      (turso != null || supabase != null || r2 != null) &&
      (turso == null || turso!.success) &&
      (supabase == null || supabase!.success) &&
      (r2 == null || r2!.success);
  bool get partialSuccess =>
      !success &&
      (turso?.success == true ||
          supabase?.success == true ||
          r2?.success == true);

  String get message {
    if (turso == null && supabase == null && r2 == null) {
      return 'Cloud sync is not configured.';
    }
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
    // Between Turso and R2, on the same rationale Turso goes first for: its
    // pull may add recording rows whose media R2 can then fetch.
    if (supabase case final SupabaseSyncResult result) {
      if (result.success) {
        final List<String> counts = <String>[
          '${result.pushed} pushed',
          '${result.pulled} pulled',
          if (result.conflicts > 0) '${result.conflicts} conflicts',
          if (result.tombstonesApplied > 0) '${result.tombstonesApplied} removed',
          if (result.skipped > 0) '${result.skipped} skipped',
        ];
        lines.add('Supabase: ${counts.join(' · ')}');
      } else {
        lines.add('Supabase: ${result.failureReason ?? 'sync failed'}');
      }
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
    this.syncSupabase,
    this.syncR2,
  });

  final String configurationFingerprint;
  final Future<TursoSyncResult> Function()? syncTurso;
  final Future<SupabaseSyncResult> Function()? syncSupabase;
  final Future<R2SyncResult> Function()? syncR2;

  Future<CloudSyncReport> sync() async {
    TursoSyncResult? turso;
    SupabaseSyncResult? supabase;
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

    // Between Turso and R2, on the same rationale Turso goes first for: its
    // pull may add recording rows whose media R2 can then fetch.
    if (syncSupabase != null) {
      try {
        supabase = await syncSupabase!();
      } catch (error) {
        supabase = SupabaseSyncResult(
          failureReason: 'Supabase sync failed (${error.runtimeType}).',
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
      supabase: supabase,
      r2: r2,
    );
  }
}
