import 'package:flutter/material.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../domain/clipboard_watcher_service.dart';
import 'clipboard_history_sheet.dart';

class ClipboardTab extends StatelessWidget {
  const ClipboardTab({
    super.key,
    required this.watcherService,
    required this.recordingsController,
  });

  final ClipboardWatcherService watcherService;
  final RecordingsController recordingsController;

  @override
  Widget build(BuildContext context) {
    return ClipboardHistorySheet(
      watcherService: watcherService,
      recordingsController: recordingsController,
    );
  }
}
