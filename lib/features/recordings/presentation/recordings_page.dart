import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../logs/data/log_store.dart';
import '../../logs/presentation/logs_tab.dart';
import '../../processing/data/ocr_service.dart';
import '../../processing/data/video_audio_extractor.dart';
import '../../settings/presentation/config_tab.dart';
import '../../settings/presentation/models_tab.dart';
import '../../settings/presentation/settings_controller.dart';
import '../../transcription/data/transcription_service.dart';
import '../data/recordings_repository.dart';
import '../domain/capture_type.dart';
import 'queue_tab.dart';
import 'recordings_controller.dart';

/// Shell for the four navigation tabs. Owns the controllers and keeps the
/// recordings controller in sync with settings; every tab body lives in its own
/// file.
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  // Indices used in code; Logs (2) and Config (3) are only ever selected by the
  // NavigationBar itself.
  static const int queueIndex = 0;
  static const int modelsIndex = 1;

  final RecordingsRepository repository = RecordingsRepository();
  late final SettingsController settings;
  late final LogStore logs;
  late final RecordingsController controller;
  late final Listenable listenable;

  int navigationIndex = queueIndex;
  String? storagePath;

  @override
  void initState() {
    super.initState();
    settings = SettingsController();
    logs = LogStore(archive: FileLogArchive());
    controller = RecordingsController(
      repository: repository,
      // Replaced as soon as settings load; a fresh install with no profile
      // keeps this disabled service, which is the pre-existing behaviour.
      transcriptionService: const DisabledTranscriptionService(),
      ocrService: _buildOcrService(),
      videoAudioExtractor: _buildVideoAudioExtractor(),
      logSink: logs,
    );

    settings.addListener(_applySettings);
    listenable = Listenable.merge(<Listenable>[controller, settings, logs]);
    _bootstrap();
  }

  /// Desktop shells out to the system `tesseract` binary (fails cleanly if it is
  /// absent). Mobile has no OCR yet — ML Kit is a later slice — so it degrades
  /// to the disabled service, which reports "not configured" and stays retryable.
  static OcrService _buildOcrService() {
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      return const TesseractOcrService();
    }
    return const DisabledOcrService();
  }

  /// Desktop extracts the audio track with the system `ffmpeg` binary (fails
  /// cleanly if absent), then reuses the transcription pipeline. Mobile has no
  /// ffmpeg yet — ffmpeg_kit is a later add — so it degrades to "unavailable".
  static VideoAudioExtractor _buildVideoAudioExtractor() {
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      return const FfmpegVideoAudioExtractor();
    }
    return const UnavailableVideoAudioExtractor();
  }

  Future<void> _bootstrap() async {
    await logs.initialize();
    // Settings first so the very first recording already uses the saved
    // provider and capture parameters.
    await settings.initialize();
    await controller.initialize();

    final Directory directory = await repository.recordingsDirectory();
    if (!mounted) return;
    setState(() => storagePath = directory.path);
  }

  /// Push provider + audio changes into the recordings controller. Only affects
  /// work started after the swap.
  void _applySettings() {
    controller.transcriptionService = settings.transcriptionService;
    controller.audioConfig = settings.audio;
  }

  Future<void> _composeTextNote(BuildContext context) async {
    final String? body = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Console.background,
      builder: (BuildContext context) => const _TextNoteSheet(),
    );
    if (body != null && body.trim().isNotEmpty) {
      await controller.addTextNote(body);
    }
  }

  Future<void> _openCaptureMenu(BuildContext context) async {
    final _CaptureAction? action = await showModalBottomSheet<_CaptureAction>(
      context: context,
      backgroundColor: Console.background,
      builder: (BuildContext context) => const _CaptureMenuSheet(),
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case _CaptureAction.textNote:
        await _composeTextNote(context);
      case _CaptureAction.audioUpload:
        await controller.addUpload(CaptureType.audioUpload);
      case _CaptureAction.imageUpload:
        await controller.addUpload(CaptureType.image);
      case _CaptureAction.videoUpload:
        await controller.addUpload(CaptureType.video);
    }
  }

  @override
  void dispose() {
    settings.removeListener(_applySettings);
    controller.dispose();
    settings.dispose();
    logs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: listenable,
      builder: (BuildContext context, Widget? child) {
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 20,
            title: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Audivoa Core',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 21),
                ),
                Text(
                  'LOCAL-FIRST PROCESSING CONSOLE',
                  style: TextStyle(
                    color: Console.muted,
                    fontSize: 9,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              Padding(
                padding: const EdgeInsets.only(right: 18),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Console.cyan,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    'AI',
                    style: TextStyle(
                      color: Console.ink,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ],
          ),
          // IndexedStack so the Queue tab keeps its search text and filter
          // while the user visits Models/Logs/Config.
          body: IndexedStack(
            index: navigationIndex,
            children: <Widget>[
              QueueTab(controller: controller),
              ModelsTab(controller: settings),
              LogsTab(store: logs),
              ConfigTab(
                controller: settings,
                storagePath: storagePath,
                recordingsCount: controller.recordings.length,
                logCount: logs.events.length,
                onOpenModels: () =>
                    setState(() => navigationIndex = modelsIndex),
              ),
            ],
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          floatingActionButton: navigationIndex == queueIndex
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    // Non-audio capture. Hidden while recording so the stop
                    // action stands alone.
                    if (!controller.isRecording && !controller.isBusy) ...<Widget>[
                      FloatingActionButton.small(
                        heroTag: 'add',
                        backgroundColor: Console.surfaceRaised,
                        foregroundColor: Console.cyan,
                        onPressed: () => _openCaptureMenu(context),
                        child: const Icon(Icons.add),
                      ),
                      const SizedBox(height: 12),
                    ],
                    RecordButton(controller: controller),
                  ],
                )
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: navigationIndex,
            onDestinationSelected: (int value) {
              setState(() => navigationIndex = value);
            },
            destinations: <NavigationDestination>[
              const NavigationDestination(
                icon: Icon(Icons.inbox_outlined),
                selectedIcon: Icon(Icons.inbox),
                label: 'Queue',
              ),
              NavigationDestination(
                icon: _ProfileBadge(
                  hasActiveProfile: settings.activeProfile != null,
                  selected: false,
                ),
                selectedIcon: _ProfileBadge(
                  hasActiveProfile: settings.activeProfile != null,
                  selected: true,
                ),
                label: 'Models',
              ),
              const NavigationDestination(
                icon: Icon(Icons.terminal_outlined),
                selectedIcon: Icon(Icons.terminal),
                label: 'Logs',
              ),
              const NavigationDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: 'Config',
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Amber dot on the Models tab while no provider profile is active, so the
/// "transcription is off" state is visible without opening the tab.
class _ProfileBadge extends StatelessWidget {
  const _ProfileBadge({required this.hasActiveProfile, required this.selected});

  final bool hasActiveProfile;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final Icon icon = selected
        ? const Icon(Icons.memory)
        : const Icon(Icons.memory_outlined);
    if (hasActiveProfile) return icon;

    return Badge(
      backgroundColor: Console.amber,
      smallSize: 7,
      child: icon,
    );
  }
}

/// Compose sheet for a text note. Returns the typed body via `Navigator.pop`;
/// the page persists it through `RecordingsController.addTextNote`.
class _TextNoteSheet extends StatefulWidget {
  const _TextNoteSheet();

  @override
  State<_TextNoteSheet> createState() => _TextNoteSheetState();
}

class _TextNoteSheetState extends State<_TextNoteSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _canSave = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final bool next = _controller.text.trim().isNotEmpty;
      if (next != _canSave) setState(() => _canSave = next);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 18, 18, bottomInset + 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Nowa notatka',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 6,
            minLines: 3,
            style: const TextStyle(color: Console.text, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Wpisz treść notatki…',
              hintStyle: const TextStyle(color: Console.muted, fontSize: 13),
              filled: true,
              fillColor: Console.surfaceDeep,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Console.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Console.border),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _canSave
                  ? () => Navigator.pop(context, _controller.text)
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: Console.cyan,
                foregroundColor: Console.ink,
                disabledBackgroundColor: Console.surfaceRaised,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Zapisz notatkę'),
            ),
          ),
        ],
      ),
    );
  }
}

enum _CaptureAction { textNote, audioUpload, imageUpload, videoUpload }

/// Menu of non-recording capture options, opened from the "+" FAB. Recording
/// audio stays on its own dedicated button.
class _CaptureMenuSheet extends StatelessWidget {
  const _CaptureMenuSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 8),
          _row(context, Icons.sticky_note_2_outlined, 'Nowa notatka',
              _CaptureAction.textNote),
          _row(context, Icons.audio_file_outlined, 'Wgraj plik audio',
              _CaptureAction.audioUpload),
          _row(context, Icons.image_outlined, 'Wgraj obraz',
              _CaptureAction.imageUpload),
          _row(context, Icons.movie_outlined, 'Wgraj wideo',
              _CaptureAction.videoUpload),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String label,
      _CaptureAction action) {
    return ListTile(
      leading: Icon(icon, color: Console.cyan),
      title: Text(label,
          style: const TextStyle(
              color: Console.text, fontWeight: FontWeight.w700, fontSize: 14)),
      onTap: () => Navigator.pop(context, action),
    );
  }
}
