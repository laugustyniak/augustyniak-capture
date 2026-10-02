import '../../features/sync/domain/media_sync.dart';
import '../../features/sync/domain/sync_snapshot.dart';

enum CloudSyncStage { checking, metadata, storage, complete }

class CloudSyncProgress {
  const CloudSyncProgress(this.stage, {this.supabase, this.media});

  final CloudSyncStage stage;
  final SupabaseSyncResult? supabase;
  final MediaSyncResult? media;
}

class CloudSyncReport {
  const CloudSyncReport({required this.completedAt, this.supabase, this.media});

  final DateTime completedAt;
  final SupabaseSyncResult? supabase;
  final MediaSyncResult? media;

  bool get success =>
      (supabase != null || media != null) &&
      (supabase == null || supabase!.success) &&
      (media == null || media!.success);
  bool get partialSuccess =>
      !success && (supabase?.success == true || media?.success == true);

  String get message {
    if (supabase == null && media == null) {
      return 'Cloud sync is not configured.';
    }
    final String headline = success
        ? 'Sync completed'
        : partialSuccess
        ? 'Sync partially completed'
        : 'Sync failed';
    final List<String> lines = <String>[headline];
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
    if (media case final MediaSyncResult result) {
      final List<String> counts = <String>[
        if (result.uploaded > 0) '${result.uploaded} uploaded',
        if (result.downloaded > 0) '${result.downloaded} downloaded',
        if (result.unchanged > 0) '${result.unchanged} unchanged',
        if (result.waiting > 0) '${result.waiting} waiting',
        if (result.unverifiable > 0) '${result.unverifiable} unverifiable',
        if (result.rejected > 0) '${result.rejected} rejected',
      ];
      final String detail = counts.isEmpty ? 'no files' : counts.join(' · ');
      lines.add(
        result.success
            ? 'Storage: $detail'
            : 'Storage: ${result.failureReason ?? 'sync failed'} · $detail',
      );
    }
    return lines.join('\n');
  }
}

class CloudSyncCoordinator {
  const CloudSyncCoordinator({this.syncSupabase, this.syncMedia});

  final Future<SupabaseSyncResult> Function()? syncSupabase;
  final Future<MediaSyncResult> Function()? syncMedia;

  Future<CloudSyncReport> sync({
    void Function(CloudSyncProgress)? onProgress,
  }) async {
    SupabaseSyncResult? supabase;
    MediaSyncResult? media;

    if (syncSupabase != null) {
      onProgress?.call(const CloudSyncProgress(CloudSyncStage.metadata));
      try {
        supabase = await syncSupabase!();
      } catch (error) {
        supabase = SupabaseSyncResult(
          failureReason: 'Supabase sync failed (${error.runtimeType}).',
        );
      }
    }

    // After the metadata pull, which is what adds the rows whose media this
    // slot fetches.
    if (syncMedia != null) {
      onProgress?.call(
        CloudSyncProgress(CloudSyncStage.storage, supabase: supabase),
      );
      try {
        media = await syncMedia!();
      } catch (error) {
        media = MediaSyncResult(
          failureReason: 'Storage sync failed (${error.runtimeType}).',
        );
      }
    }

    onProgress?.call(
      CloudSyncProgress(
        CloudSyncStage.complete,
        supabase: supabase,
        media: media,
      ),
    );
    return CloudSyncReport(
      completedAt: DateTime.now(),
      supabase: supabase,
      media: media,
    );
  }
}
