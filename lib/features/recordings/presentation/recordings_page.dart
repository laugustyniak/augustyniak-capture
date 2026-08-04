import 'dart:async';
import 'dart:io';

// `setEquals` lives in foundation and is NOT among the handful of symbols
// material re-exports from it.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../logs/data/log_store.dart';
import '../../logs/presentation/logs_tab.dart';
import '../../processing/data/ocr_service.dart';
import '../../processing/data/video_audio_extractor.dart';
import '../../processing/data/video_poster_extractor.dart';
import '../../projects/data/ghostty_zellij_agent_session_launcher.dart';
import '../../projects/data/projects_repository.dart';
import '../../projects/presentation/projects_controller.dart';
import '../../projects/presentation/projects_tab.dart';
import '../../settings/presentation/config_tab.dart';
import '../../settings/presentation/models_tab.dart';
import '../../settings/presentation/settings_controller.dart';
import '../../shortcuts/data/linux_hotkey_registrar.dart';
import '../../shortcuts/data/system_hotkey_registrar.dart';
import '../../shortcuts/data/system_window_presenter.dart';
import '../../shortcuts/domain/hotkey_registrar.dart';
import '../../shortcuts/domain/shortcut_action.dart';
import '../../shortcuts/domain/window_presenter.dart';
import '../../shortcuts/presentation/shortcuts_coordinator.dart';
import '../../transcription/data/transcription_service.dart';
import '../data/recordings_repository.dart';
import '../data/system_clipboard_sink.dart';
import '../data/revisions_repository.dart';
import '../data/system_media_opener.dart';
import '../domain/capture_type.dart';
import 'capture_dock.dart';
import 'queue_tab.dart';
import 'recording_view.dart';
import 'recordings_controller.dart';
import 'text_note_sheet.dart';

/// Shell for the five navigation tabs. Owns the controllers and keeps the
/// recordings controller in sync with settings; every tab body lives in its own
/// file.
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  // Indices used in code; Projects, Logs and Config are selected only by the
  // NavigationBar itself.
  static const int queueIndex = 0;
  static const int modelsIndex = 2;

  final RecordingsRepository repository = RecordingsRepository();
  late final SettingsController settings;
  late final LogStore logs;
  late final RecordingsController controller;
  late final ProjectsController projects;
  late final ShortcutsCoordinator shortcuts;
  late final Listenable listenable;

  int navigationIndex = queueIndex;
  String? storagePath;

  /// Reported by the registrar so the Config tab can flag a combination the OS
  /// refused instead of leaving it silently dead.
  Set<ShortcutAction> rejectedShortcuts = const <ShortcutAction>{};

  @override
  void initState() {
    super.initState();
    settings = SettingsController();
    logs = LogStore(archive: FileLogArchive());
    projects = ProjectsController(
      repository: ProjectsRepository(),
      launcher: Platform.isMacOS ? GhosttyZellijAgentSessionLauncher() : null,
    );
    controller = RecordingsController(
      repository: repository,
      // Records what the enrichment model and hand edits overwrite. Left null
      // in tests, like the clipboard and media-opener seams, so the pure-Dart
      // suites never reach a platform channel.
      revisionsRepository: RevisionsRepository(),
      // Replaced as soon as settings load; a fresh install with no profile
      // keeps this disabled service, which is the pre-existing behaviour. The
      // enrichment service is left at its disabled default here for the same
      // reason — `_applySettings` pushes both once `settings.initialize()` has
      // notified.
      transcriptionService: const DisabledTranscriptionService(),
      ocrService: _buildOcrService(),
      videoAudioExtractor: _buildVideoAudioExtractor(),
      videoPosterExtractor: _buildVideoPosterExtractor(),
      logSink: logs,
      // Finished processor output lands on the system clipboard, so a clipboard
      // manager keeps it in history. Tests get the no-op default instead.
      clipboardSink: const SystemClipboardSink(),
      // Video plays in whatever the platform already uses for it; tests get the
      // no-op default.
      mediaOpener: const SystemMediaOpener(),
    );
    shortcuts = ShortcutsCoordinator(
      recordings: controller,
      // Read lazily rather than capturing `context` here: a hotkey can fire long
      // after initState, and the sheet must open against the live element.
      composeTextNote: () async {
        if (!mounted) return;
        await _composeTextNote(context);
      },
      // The capture screen overlays whichever tab is showing, so a
      // hotkey-started recording is visible immediately. This still runs, so
      // that stopping leaves the user on the Queue — where the capture they
      // just made is now sitting — rather than on Models or Config.
      revealQueue: () async {
        if (!mounted || navigationIndex == queueIndex) return;
        setState(() => navigationIndex = queueIndex);
      },
      registrar: _buildHotkeyRegistrar(),
      windowPresenter: _buildWindowPresenter(),
      logSink: logs,
    );

    settings.addListener(_applySettings);
    projects.addListener(_applyActiveProject);
    listenable = Listenable.merge(<Listenable>[
      controller,
      projects,
      settings,
      logs,
    ]);
    _bootstrap();
  }

  /// Desktop shells out to the system `tesseract` binary (fails cleanly if it is
  /// absent). Mobile has no OCR yet — ML Kit is a later slice — so it degrades
  /// to the disabled service, which reports "not configured" and stays retryable.
  static OcrService _buildOcrService() {
    if (_isDesktop) {
      return const TesseractOcrService();
    }
    return const DisabledOcrService();
  }

  /// Desktop extracts the audio track with the system `ffmpeg` binary (fails
  /// cleanly if absent), then reuses the transcription pipeline. Mobile has no
  /// ffmpeg yet — ffmpeg_kit is a later add — so it degrades to "unavailable".
  static VideoAudioExtractor _buildVideoAudioExtractor() {
    if (_isDesktop) {
      return const FfmpegVideoAudioExtractor();
    }
    return const UnavailableVideoAudioExtractor();
  }

  /// Same story for the poster frame: desktop pulls one still with the system
  /// `ffmpeg` (fails cleanly if absent, costing only the thumbnail), mobile has
  /// no ffmpeg yet and degrades to "unavailable".
  static VideoPosterExtractor _buildVideoPosterExtractor() {
    if (_isDesktop) {
      return const FfmpegVideoPosterExtractor();
    }
    return const UnavailableVideoPosterExtractor();
  }

  /// Desktop is where the system `tesseract`/`ffmpeg` binaries and OS-wide
  /// hotkeys exist. Mobile gets the disabled/no-op seams instead, so those
  /// features cost nothing there and the Config tab hides the shortcuts section.
  static bool get _isDesktop =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  /// Linux gets its own registrar rather than `hotkey_manager`'s Dart layer,
  /// which resolves some keys to the wrong physical key on the way to GTK — see
  /// [LinuxHotkeyRegistrar].
  static HotkeyRegistrar _buildHotkeyRegistrar() {
    if (Platform.isLinux) return LinuxHotkeyRegistrar();
    return _isDesktop
        ? const SystemHotkeyRegistrar()
        : const NoopHotkeyRegistrar();
  }

  static WindowPresenter _buildWindowPresenter() =>
      _isDesktop ? const SystemWindowPresenter() : const NoopWindowPresenter();

  Future<void> _bootstrap() async {
    await logs.initialize();
    // Settings first so the very first recording already uses the saved
    // provider and capture parameters.
    await settings.initialize();
    await projects.initialize();
    _applyActiveProject();
    await controller.initialize();
    // After loading, never inside it: this reads the recordings *directory*, so
    // it belongs to the shell that knows the directory is the real one. On a
    // healthy install it costs one listing and finds nothing.
    await controller.recoverOrphans();
    // Explicit rather than relying on the notification `initialize` emits, so
    // the hotkeys are guaranteed live once bootstrap returns.
    await _applyShortcuts();

    final Directory directory = await repository.recordingsDirectory();
    if (!mounted) return;
    setState(() => storagePath = directory.path);
  }

  /// Push provider + audio changes into the recordings controller. Only affects
  /// work started after the swap.
  void _applySettings() {
    controller.transcriptionService = settings.transcriptionService;
    controller.enrichmentService = settings.enrichmentService;
    // OCR rides the enrichment profile (vision-capable chat endpoint). With no
    // profile active it falls back to the platform default — tesseract on
    // desktop, disabled on mobile — so a fresh install behaves as before.
    final OcrService ocr = settings.ocrService;
    controller.ocrService = ocr is DisabledOcrService
        ? _buildOcrService()
        : ocr;
    controller.audioConfig = settings.audio;
    // Fire-and-forget: an unchanged binding map short-circuits inside the
    // coordinator, so this does not churn the OS hotkey table on every
    // unrelated settings change.
    unawaited(_applyShortcuts());
  }

  void _applyActiveProject() {
    controller.activeProjectId = projects.activeProjectId;
  }

  Future<void> _applyShortcuts() async {
    final Set<ShortcutAction> rejected = await shortcuts.apply(
      settings.settings.shortcuts,
    );
    if (!mounted || setEquals(rejected, rejectedShortcuts)) return;
    setState(() => rejectedShortcuts = rejected);
  }

  /// Pairs suspend/resume in one place so the Config tab cannot leak a
  /// suspended state if the capture sheet throws or is dismissed.
  Future<void> _runWithHotkeysSuspended(Future<void> Function() action) async {
    await shortcuts.suspend();
    try {
      await action();
    } finally {
      await shortcuts.resume();
      // Re-read the refusal set. A rebind notifies settings while the hotkeys
      // are still suspended, so that `apply` short-circuits and hands back the
      // pre-suspend value; only `resume` re-registers and learns what the OS
      // actually refused. Without this the Config tab keeps showing the stale
      // amber flags until some unrelated setting changes.
      await _applyShortcuts();
    }
  }

  Future<void> _composeTextNote(BuildContext context) async {
    final String? body = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Console.background,
      builder: (BuildContext context) => const TextNoteSheet(),
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
    projects.removeListener(_applyActiveProject);
    // The OS keeps a registration until it is told otherwise. This cannot be
    // awaited here, so the coordinator sets its `_disposed` flag synchronously
    // and refuses presses landing in the gap before the unregister completes.
    unawaited(shortcuts.dispose());
    controller.dispose();
    projects.dispose();
    settings.dispose();
    logs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: listenable,
      builder: (BuildContext context, Widget? child) {
        final bool recording = controller.isRecording;

        return Scaffold(
          // No AppBar: each tab draws the design's own header (cyan eyebrow +
          // large title) inside its scroll area, so the title scrolls with the
          // content instead of sitting in a separate bar above it.
          body: Stack(
            children: <Widget>[
              // IndexedStack so the Queue tab keeps its search text and filter
              // while the user visits Models/Logs/Config.
              IndexedStack(
                index: navigationIndex,
                children: <Widget>[
                  QueueTab(controller: controller, projects: projects),
                  ProjectsTab(controller: projects),
                  ModelsTab(controller: settings),
                  LogsTab(store: logs),
                  ConfigTab(
                    controller: settings,
                    storagePath: storagePath,
                    recordingsCount: controller.recordings.length,
                    logCount: logs.events.length,
                    onOpenModels: () =>
                        setState(() => navigationIndex = modelsIndex),
                    showShortcuts: _isDesktop,
                    rejectedShortcuts: rejectedShortcuts,
                    runWithHotkeysSuspended: _runWithHotkeysSuspended,
                  ),
                ],
              ),
              if (navigationIndex == queueIndex && !recording)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: CaptureDock(
                    controller: controller,
                    onOpenCaptureMenu: () => _openCaptureMenu(context),
                  ),
                ),
              // Overlaid rather than swapped into the IndexedStack: the Queue
              // underneath keeps its search text and scroll position for when
              // the capture finishes.
              if (recording)
                Positioned.fill(
                  child: ColoredBox(
                    color: Console.background,
                    child: RecordingView(controller: controller),
                  ),
                ),
            ],
          ),
          // Hidden while recording — the capture screen is a single-purpose
          // view, and switching tabs mid-take is not a thing to invite.
          bottomNavigationBar: recording
              ? null
              : DecoratedBox(
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Console.border)),
                  ),
                  child: NavigationBar(
                    selectedIndex: navigationIndex,
                    onDestinationSelected: (int value) {
                      setState(() => navigationIndex = value);
                    },
                    destinations: <NavigationDestination>[
                      const NavigationDestination(
                        icon: Icon(Icons.format_list_bulleted_rounded),
                        label: 'QUEUE',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.account_tree_outlined),
                        label: 'PROJECTS',
                      ),
                      NavigationDestination(
                        icon: _ProfileBadge(
                          hasActiveProfile: settings.activeProfile != null,
                        ),
                        label: 'MODELS',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.chevron_right_rounded),
                        label: 'LOGS',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.tune_rounded),
                        label: 'CONFIG',
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

/// Amber dot on the Models tab while no provider profile is active, so the
/// "transcription is off" state is visible without opening the tab.
///
/// One icon for both states: the navigation theme already tints it cyan when
/// selected and dim when not, which is how the design marks the active tab.
class _ProfileBadge extends StatelessWidget {
  const _ProfileBadge({required this.hasActiveProfile});

  final bool hasActiveProfile;

  @override
  Widget build(BuildContext context) {
    const Icon icon = Icon(Icons.memory_rounded);
    if (hasActiveProfile) return icon;

    return const Badge(
      backgroundColor: Console.amber,
      smallSize: 7,
      child: icon,
    );
  }
}

enum _CaptureAction { textNote, audioUpload, imageUpload, videoUpload }

/// Menu of non-recording capture options, opened from the note button on the
/// capture dock. Recording audio stays on its own dedicated button.
class _CaptureMenuSheet extends StatelessWidget {
  const _CaptureMenuSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Console.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: Console.borderStrong),
          left: BorderSide(color: Console.borderStrong),
          right: BorderSide(color: Console.borderStrong),
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Console.borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            _row(
              context,
              Icons.description_outlined,
              'New text note',
              'typed · passthrough',
              _CaptureAction.textNote,
            ),
            _row(
              context,
              Icons.audio_file_outlined,
              'Upload audio',
              'transcribed',
              _CaptureAction.audioUpload,
            ),
            _row(
              context,
              Icons.image_outlined,
              'Upload image',
              'OCR',
              _CaptureAction.imageUpload,
            ),
            _row(
              context,
              Icons.movie_outlined,
              'Upload video',
              'audio track · transcribed',
              _CaptureAction.videoUpload,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    IconData icon,
    String label,
    String hint,
    _CaptureAction action,
  ) {
    return ListTile(
      leading: ConsoleIconTile(icon: icon, size: 36),
      title: Text(label, style: ConsoleText.cardTitle),
      // States which processor the item will land in — the same fact the card
      // will show afterwards, so the choice is not a guess.
      subtitle: Text(hint, style: ConsoleText.micro),
      onTap: () => Navigator.pop(context, action),
    );
  }
}
