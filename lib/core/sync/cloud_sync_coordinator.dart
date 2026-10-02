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
  bool get hasItemConflicts => supabase?.conflictDetails.any(
        (SyncConflictDetail detail) => !detail.isBookkeeping,
      ) ?? false;

  String get message {
    if (supabase == null && media == null) {
      return 'Cloud sync is not configured.';
    }
    final String headline = success
        ? (hasItemConflicts ? 'Sync completed with conflicts' : 'Sync completed')
        : partialSuccess
        ? 'Sync partially completed'
        : 'Sync failed';
    final List<String> lines = <String>[headline];
    if (supabase case final SupabaseSyncResult result) {
      final List<SyncConflictDetail> dataConflicts = result.conflictDetails
          .where((SyncConflictDetail detail) => !detail.isBookkeeping)
          .toList();
      final int bookkeepingConflicts =
          result.conflictDetails.length - dataConflicts.length;
      if (result.success) {
        final List<String> counts = <String>[
          '${result.pushed} pushed',
          '${result.pulled} pulled',
          if (dataConflicts.isNotEmpty)
            '${dataConflicts.length} item conflict${dataConflicts.length == 1 ? '' : 's'}',
          if (bookkeepingConflicts > 0)
            '$bookkeepingConflicts sync state conflict${bookkeepingConflicts == 1 ? '' : 's'}',
          if (result.conflicts > result.conflictDetails.length)
            result.conflictDetails.isEmpty
                ? '${result.conflicts} conflicts'
                : '${result.conflicts - result.conflictDetails.length} other conflicts',
          if (result.tombstonesApplied > 0)
            '${result.tombstonesApplied} removed',
          if (result.skipped > 0) '${result.skipped} skipped',
        ];
        lines.add('Supabase: ${counts.join(' · ')}');
      } else {
        lines.add('Supabase: ${result.failureReason ?? 'sync failed'}');
        if (result.conflicts > 0) {
          lines.add('Before failure: ${dataConflicts.length} item '
              'conflict${dataConflicts.length == 1 ? '' : 's'} · '
              '$bookkeepingConflicts sync state '
              'conflict${bookkeepingConflicts == 1 ? '' : 's'}'
              '${result.conflicts > result.conflictDetails.length ? ' · ${result.conflicts - result.conflictDetails.length} unclassified' : ''}');
        }
      }
      for (final SyncConflictDetail detail in dataConflicts.take(5)) {
        final String subject = switch (detail.table) {
          'recordings' => 'Recording',
          'segments' => 'Recording segment',
          'projects' => 'Project',
          'clipboard_items' => 'Clipboard item',
          _ => detail.table,
        };
        final String resolution = switch (detail.resolution) {
          SyncConflictResolution.serverApplied => 'server version applied',
          SyncConflictResolution.serverDeleted => 'deleted on server',
          SyncConflictResolution.localTranscriptKept =>
            'server fields applied; longer local transcript kept',
          SyncConflictResolution.serverAdopted => 'server version noted',
          SyncConflictResolution.retryNeeded => 'changed again; retry sync',
        };
        final String fields = detail.overwrittenFields.isEmpty
            ? ''
            : detail.resolution == SyncConflictResolution.serverDeleted
            ? '; previous ${detail.overwrittenFields.join(', ')} saved in history file'
            : '; previous ${detail.overwrittenFields.join(', ')} in HISTORY';
        lines.add('$subject ${detail.id}: $resolution$fields');
      }
      if (dataConflicts.length > 5) {
        lines.add('${dataConflicts.length - 5} more item conflicts');
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
