import 'dart:io';

import 'package:path/path.dart' as p;

import '../../logs/domain/log_event.dart';
import '../domain/capture_archive.dart';

/// Runs an export or an import end to end: stage, hand to the picker, clean up.
///
/// It exists so neither the archive nor the widget has to know about the other.
/// The archive writes zips and knows nothing about dialogs; the Config section
/// renders two buttons and knows nothing about staging directories.
class BackupCoordinator {
  BackupCoordinator({
    required CaptureArchive archive,
    required ArchiveLocationPicker picker,
    LogSink logSink = const NoopLogSink(),
    DateTime Function() now = DateTime.now,
  }) : _archive = archive,
       _picker = picker,
       _logSink = logSink,
       _now = now;

  final CaptureArchive _archive;
  final ArchiveLocationPicker _picker;
  final LogSink _logSink;
  final DateTime Function() _now;

  /// Dated rather than timestamped: a name a person can read in a Downloads
  /// folder six months later, and one that sorts.
  String suggestedName() {
    final DateTime at = _now();
    final String month = at.month.toString().padLeft(2, '0');
    final String day = at.day.toString().padLeft(2, '0');
    return 'augustyniak-capture-${at.year}-$month-$day.zip';
  }

  /// Null when the user cancelled the save dialog. Throws when the export
  /// itself failed — a backup that silently did not happen is the one outcome
  /// this feature exists to prevent, so it is never swallowed.
  Future<BackupSummary?> export() async {
    // Staged in the system temp directory rather than written straight to the
    // destination: on the SAF path there is no destination to stream to, and on
    // every path a cancelled dialog must leave nothing behind at the target.
    final Directory staging = await Directory.systemTemp.createTemp(
      'augustyniak_capture_export_',
    );
    final File staged = File(p.join(staging.path, suggestedName()));
    try {
      final BackupSummary summary = await _archive.exportTo(staged);
      final String? destination = await _picker.deliver(
        staged,
        suggestedName(),
      );
      if (destination == null) {
        _logSink.log('Export cancelled.', level: LogLevel.warn);
        return null;
      }
      _logSink.log('Exported ${summary.captures} captures to $destination.');
      return BackupSummary(
        captures: summary.captures,
        files: summary.files,
        bytes: summary.bytes,
        destination: destination,
      );
    } finally {
      // Best effort: a temp directory left behind is litter, and failing to
      // remove it must not replace the error the caller is reporting.
      try {
        await staging.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Null when the user cancelled. Throws on an unreadable archive.
  Future<RestoreSummary?> import() async {
    final File? source = await _picker.chooseArchive();
    if (source == null) {
      _logSink.log('Import cancelled.', level: LogLevel.warn);
      return null;
    }
    final RestoreSummary summary = await _archive.importFrom(source);
    _logSink.log(
      'Imported ${summary.added} captures '
      '(${summary.alreadyPresent} already here'
      '${summary.matchedByIdAlone > 0 ? ', ${summary.matchedByIdAlone} of them '
                'matched by id alone — that archive predates content hashing '
                'and its rows were not compared by content' : ''}, '
      '${summary.filesRestored} files restored).',
    );
    return summary;
  }
}
