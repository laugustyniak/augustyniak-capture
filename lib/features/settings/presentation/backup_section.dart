import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../backup/domain/capture_archive.dart';

/// The Config tab's `ARCHIVE` section: take a portable copy, or merge one in.
///
/// **The one section in this app that is about the app not being there.** Every
/// other control tunes what happens next; these two exist because on Android
/// and iOS the recordings directory lives inside the app container, and a
/// reinstall deletes it with every transcript in it. So the copy is written to
/// be read by someone who has just lost the app, and it says what an import
/// will and will not do *before* they press it — an additive restore is
/// unusual enough that assuming it would be trusted is optimistic.
class BackupSection extends StatefulWidget {
  BackupSection({super.key, this.onExport, this.onImport});

  /// Null where the host wired no archive — the buttons then render disabled
  /// rather than opening a dialog that leads nowhere. Both resolve to null when
  /// the user cancels, which is not an error and is reported as nothing at all.
  final Future<BackupSummary?> Function()? onExport;
  final Future<RestoreSummary?> Function()? onImport;

  @override
  State<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends State<BackupSection> {
  /// One at a time: both run real IO over the same directory, and a second
  /// press mid-run would interleave a merge with a read of what it is merging.
  bool _busy = false;

  /// Inline, like every other result in this app — no snackbars, and a dialog
  /// is reserved for destructive confirmation. Kept until the next run so the
  /// path an export landed on can still be read and copied.
  String? _outcome;
  bool _failed = false;

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _outcome = null;
      _failed = false;
    });
    String? message;
    bool failed = false;
    try {
      message = await action();
    } catch (exception) {
      message = '$exception';
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _outcome = message;
      _failed = failed;
    });
  }

  Future<void> _export() => _run(() async {
    final BackupSummary? summary = await widget.onExport!();
    if (summary == null) return null; // cancelled
    final String size = formatBytes(summary.bytes) ?? '${summary.bytes} B';
    return '${summary.captures} captures · $size → ${summary.destination}';
  });

  Future<void> _import() => _run(() async {
    final RestoreSummary? summary = await widget.onImport!();
    if (summary == null) return null;
    // Every number, including the zeroes. "Restored 0" has three causes and
    // only one of them is a problem, so a single count would report a
    // successful no-op and a broken archive in the same words.
    final List<String> parts = <String>[
      '${summary.added} restored',
      '${summary.alreadyPresent} already here',
      // Named on screen, not only in the log: an archive taken before content
      // hashing looks perfectly deduplicated while nothing was compared by
      // content, and the user is the only one who can tell whether that
      // matters for the copy they are restoring.
      if (summary.matchedByIdAlone > 0)
        '${summary.matchedByIdAlone} matched by id only',
      '${summary.filesRestored} files',
      if (summary.unreadable > 0) '${summary.unreadable} unreadable',
    ];
    return parts.join(' · ');
  });

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionHeader(title: 'ARCHIVE'),
          const SizedBox(height: 10),
          Text(
            'A zip of every capture, its source file and the text that was '
            'made from it. On a phone the recordings live inside the app '
            'container, which a reinstall deletes — this is the only copy that '
            'survives that.',
            style: ConsoleText.micro,
          ),
          const SizedBox(height: 6),
          Text(
            'Importing only adds: a capture already here is left untouched, and '
            'no file is overwritten. Provider tokens are never exported.',
            style: ConsoleText.micro,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            children: <Widget>[
              TextButton.icon(
                onPressed: _busy || widget.onExport == null ? null : _export,
                icon: const Icon(Icons.archive_outlined, size: 17),
                label: const Text('EXPORT ARCHIVE'),
              ),
              TextButton.icon(
                onPressed: _busy || widget.onImport == null ? null : _import,
                icon: const Icon(Icons.unarchive_outlined, size: 17),
                label: const Text('IMPORT ARCHIVE'),
              ),
            ],
          ),
          if (_busy) ...<Widget>[
            const SizedBox(height: 10),
            Text('WORKING…', style: ConsoleText.micro),
          ],
          if (_outcome != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(
                    _outcome!,
                    style: ConsoleText.micro.copyWith(
                      color: _failed ? Console.red : Console.textSoft,
                    ),
                  ),
                ),
                // The destination is the one thing worth carrying elsewhere,
                // and it is routinely longer than the row can show.
                CopyButton(text: _outcome!),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
