import 'dart:async';
import 'dart:io';

// `setEquals` lives in foundation and is NOT among the handful of symbols
// material re-exports from it.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../app/ui_kit.dart';
import '../../clipboard/domain/clipboard_watcher_service.dart';
import '../../clipboard/presentation/clipboard_history_sheet.dart';
import '../../clipboard/presentation/clipboard_tab.dart';
import '../../enrichment/data/composed_enrichment_context_source.dart';
import '../../logs/data/log_store.dart';
import '../../logs/presentation/logs_tab.dart';
import '../../processing/data/native_media_processor.dart';
import '../../processing/data/video_audio_extractor.dart';
import '../../processing/data/video_poster_extractor.dart';
import '../../projects/data/ghostty_zellij_agent_session_launcher.dart';
import '../../projects/data/projects_repository.dart';
import '../../projects/domain/agent_session_launcher.dart';
import '../../projects/domain/project.dart';
import '../../settings/data/aes_gcm_token_cipher.dart';
import '../../settings/data/secure_storage_master_key_store.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/domain/app_theme_mode.dart';
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
import '../../timer/data/asset_alarm_player.dart';
import '../../timer/data/file_focus_session_log.dart';
import '../../timer/domain/focus_session.dart';
import '../../timer/presentation/focus_timer_controller.dart';
import '../../timer/presentation/timer_tab.dart';
import '../../transcription/data/audio_splitter.dart';
import '../../transcription/data/chunked_transcription_service.dart';
import '../../transcription/data/transcription_service.dart';
import '../../transcription/domain/transcription_limits.dart';
import '../../gamification/presentation/celebration_overlay.dart';
import '../../gamification/presentation/gamification_controller.dart';
import '../../clipboard/data/sqlite_clipboard_repository.dart';
import '../data/markdown_note_vault.dart';
import '../data/project_agent_handoff.dart';
import '../data/project_inbox_router.dart';
import '../data/recordings_repository.dart';
import '../data/system_clipboard_sink.dart';
import '../data/revisions_repository.dart';
import '../data/system_media_opener.dart';
import '../domain/agent_handoff.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import 'capture_dock.dart';
import 'capture_nav_bar.dart';
import 'nav_rail.dart';
import 'queue_tab.dart';
import 'recording_view.dart';
import 'recordings_controller.dart';
import 'text_note_sheet.dart';

/// Shell for the six navigation tabs. Owns the controllers and keeps the
/// recordings controller in sync with settings; every tab body lives in its own
/// file.
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key, this.themeMode});

  /// Where the shell publishes the persisted theme so `AugustyniakCaptureApp`,
  /// which sits *above* this page, can read it. Write-only from here.
  ///
  /// Null in the widget suite: a test pumps this page under its own
  /// `MaterialApp` with no theme host above it, and the palette it paints in is
  /// then whatever that test set up.
  final ValueNotifier<AppThemeMode>? themeMode;

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  // Indices used in code; Timer, Projects, Logs and Config are selected only by
  // the navigation itself.
  static const int queueIndex = 0;
  static const int timerIndex = 1;
  static const int modelsIndex = 4;

  static const List<({IconData icon, String label, String shortLabel})>
  destinations = <({IconData icon, String label, String shortLabel})>[
    (
      icon: Icons.format_list_bulleted_rounded,
      label: 'QUEUE',
      shortLabel: 'QUEUE',
    ),
    // Beside the Queue rather than beside Config: a focus session is something
    // you *do*, on the same footing as capturing, not something you set up once.
    (icon: Icons.timer_outlined, label: 'TIMER', shortLabel: 'TIMER'),
    (icon: Icons.account_tree_outlined, label: 'PROJECTS', shortLabel: 'PROJ'),
    (icon: Icons.content_paste_rounded, label: 'CLIPBOARD', shortLabel: 'CLIP'),
    (icon: Icons.memory_rounded, label: 'MODELS', shortLabel: 'MODELS'),
    (icon: Icons.chevron_right_rounded, label: 'LOGS', shortLabel: 'LOGS'),
    (icon: Icons.tune_rounded, label: 'CONFIG', shortLabel: 'CONFIG'),
  ];

  final RecordingsRepository repository = RecordingsRepository();
  late final SettingsController settings;
  late final LogStore logs;
  late final GamificationController gamification;
  late final RecordingsController controller;
  late final ProjectsController projects;
  late final FocusTimerController timer;
  late final ShortcutsCoordinator shortcuts;
  late final ClipboardWatcherService clipboardWatcher;
  late final Listenable listenable;

  int navigationIndex = queueIndex;
  String? storagePath;
  String? activeQueueProjectFilterId;

  /// Reported by the registrar so the Config tab can flag a combination the OS
  /// refused instead of leaving it silently dead.
  Set<ShortcutAction> rejectedShortcuts = const <ShortcutAction>{};

  /// One lookup, shared by the enrichment context and the router: both resolve
  /// a capture's `projectId` against the live list, and a project deleted after
  /// the capture was filed leaves a dangling id on the item either way.
  Project? _projectById(String id) {
    for (final Project project in projects.projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    settings = SettingsController(
      repository: SettingsRepository(
        // Real keyring-backed cipher on every platform; ensureReady degrades
        // to the plaintext behaviour when no keyring answers (headless Linux,
        // locked Secret Service, test bindings).
        cipher: AesGcmTokenCipher(
          keyStore: const SecureStorageMasterKeyStore(),
        ),
      ),
    );
    logs = LogStore(archive: FileLogArchive());
    gamification = GamificationController();
    // One launcher, two entry points: the project card starts a session with no
    // task in hand, the queue starts one on a capture. Sharing the instance is
    // what keeps them landing in the same named session rather than opening a
    // second agent on the same repository.
    final AgentSessionLauncher? launcher = Platform.isMacOS
        ? GhosttyZellijAgentSessionLauncher()
        : null;
    projects = ProjectsController(
      repository: ProjectsRepository(),
      launcher: launcher,
    );
    controller = RecordingsController(
      repository: repository,
      gamificationController: gamification,
      projectById: _projectById,
      vaultDirectory: () => settings.vaultPath == null ||
              settings.vaultPath!.trim().isEmpty
          ? null
          : Directory(p.join(settings.vaultPath!, settings.vaultFolder)),
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
      // Reads through to the two controllers on every enrichment rather than
      // capturing their state now: the user can edit their profile text, or
      // repoint a project at another repository, long after this runs.
      enrichmentContextSource: ComposedEnrichmentContextSource(
        profile: () => settings.enrichmentInstructions,
        projectById: _projectById,
      ),
      // The queue's only way out. Reads the project list live for the same
      // reason the enrichment context does: a project can be created, renamed
      // or repointed long after this runs, and the destination must follow.
      captureRouter: ProjectInboxRouter(projectById: _projectById),
      // The queue's other way out: a capture becomes an agent's opening task.
      // Disabled wherever no launcher exists, which hides the control rather
      // than offering one that can only fail.
      agentHandoff: launcher == null
          ? const DisabledAgentHandoff()
          : ProjectAgentHandoff(
              projectById: _projectById,
              launcher: launcher,
            ),
      // The second copy of every capture, as markdown. Reads its directory
      // through callbacks for the same reason the router reads its projects
      // live: the user can point it somewhere else at any time, and the very
      // next capture must follow without rebuilding anything.
      noteVault: MarkdownNoteVault(
        vaultPath: () => settings.vaultPath,
        folder: () => settings.vaultFolder,
        copySources: () => settings.vaultCopySources,
        projectName: (String id) => _projectById(id)?.name,
      ),
      // Left at the disabled default on purpose: OCR is derived entirely from
      // the enrichment profile, so `_applySettings` installs the real service
      // as soon as settings load and there is no platform engine to seed here.
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
    // Its own `AudioPlayer` inside `AssetAlarmPlayer`, never the recordings
    // controller's: an alarm must not stop a clip being reviewed, and a review
    // must not have to wait out an alarm.
    timer = FocusTimerController(
      alarmPlayer: AssetAlarmPlayer(),
      // Completed pomodoros, appended one line at a time. The only store the
      // timer has, and deliberately not part of `settings.json`: that file is
      // rewritten wholesale on every preference change, so a single failed load
      // followed by any save would replace the history with nothing.
      sessionLog: const FileFocusSessionLog(),
      // Read at the moment a session ends rather than pushed down on change:
      // the active project can be switched during a forty-minute run, and the
      // honest attribution is the one that was true when the work finished.
      // Both id and name travel, so a project deleted later does not erase the
      // hours spent on it — the same denormalisation `RouteRecord` makes.
      activeProject: () {
        final Project? active = projects.activeProject;
        return active == null
            ? null
            : FocusProject(id: active.id, name: active.name);
      },
      logSink: logs,
    );
    clipboardWatcher = ClipboardWatcherService(
      repository: SqliteClipboardRepository(),
    );
    shortcuts = ShortcutsCoordinator(
      recordings: controller,
      // The one shortcut target that is not the capture pipeline. Handed the
      // controller rather than a callback because the coordinator has to read
      // the state back — whether the press started a session decides whether
      // the window is raised at all.
      focusTimer: timer,
      // Read lazily rather than capturing `context` here: a hotkey can fire long
      // after initState, and the sheet must open against the live element.
      composeTextNote: () async {
        if (!mounted) return;
        await _composeTextNote(context);
      },
      onToggleClipboardHistory: () async {
        if (!mounted) return;
        await _showClipboardHistory(context);
      },
      // The capture screen overlays whichever tab is showing, so a
      // hotkey-started recording is visible immediately. This still runs, so
      // that stopping leaves the user on the Queue — where the capture they
      // just made is now sitting — rather than on Models or Config.
      revealQueue: () async {
        if (!mounted || navigationIndex == queueIndex) return;
        setState(() => navigationIndex = queueIndex);
      },
      // A session started from a hotkey is otherwise invisible: the dial, the
      // countdown and the alarm choice all live on one tab, and a shortcut that
      // cannot be told apart from an unregistered one is the failure this app
      // keeps designing against.
      revealTimer: () async {
        if (!mounted || navigationIndex == timerIndex) return;
        setState(() => navigationIndex = timerIndex);
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
      // State changes only — the countdown itself ticks into its own
      // `ValueNotifier`, which is what keeps a running session from rebuilding
      // all six tabs four times a second.
      timer,
    ]);
    _bootstrap();
  }

  /// Mobile uses sandbox-safe platform codecs. Desktop retains its existing
  /// ffmpeg backend until each desktop shell gets an equivalent native adapter.
  static VideoAudioExtractor _buildVideoAudioExtractor() {
    if (Platform.isAndroid || Platform.isIOS) {
      return const NativeMobileMediaProcessor();
    }
    if (_isDesktop) {
      return const FfmpegVideoAudioExtractor();
    }
    return const UnavailableVideoAudioExtractor();
  }

  /// Poster extraction follows the same native-mobile/ffmpeg-desktop split.
  static VideoPosterExtractor _buildVideoPosterExtractor() {
    if (Platform.isAndroid || Platform.isIOS) {
      return const NativeMobileMediaProcessor();
    }
    if (_isDesktop) {
      return const FfmpegVideoPosterExtractor();
    }
    return const UnavailableVideoPosterExtractor();
  }

  /// Mobile splits with platform codecs and desktop with ffmpeg. A platform
  /// without either keeps the whole-file fallback and the recording length cap.
  ///
  /// Built once and held, because two questions read this object — what wraps
  /// the transcription service, and whether recordings need a cap — and they
  /// must not be able to disagree.
  final AudioSplitter _audioSplitter = _buildAudioSplitter();

  static AudioSplitter _buildAudioSplitter() {
    if (Platform.isAndroid || Platform.isIOS) {
      return const NativeMobileMediaProcessor();
    }
    if (_isDesktop) {
      return const FfmpegAudioSplitter();
    }
    return const UnavailableAudioSplitter();
  }

  /// Desktop is where system ffmpeg and OS-wide hotkeys exist. Mobile uses
  /// platform codecs and keeps the no-op shortcut seams.
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
    // Reads the completed-session history. Awaited rather than fired off,
    // because it is one small file and an initial frame showing "0 today" that
    // corrects itself a moment later reads as data loss.
    await timer.initialize();
    await clipboardWatcher.initialize();
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
    // Wrapped, not replaced: the profile still builds the service that talks to
    // the endpoint, and this only decides how much audio each request carries.
    // Where nothing can be split the wrapper is a pass-through, so mobile keeps
    // exactly the request it made before.
    controller.transcriptionService = ChunkedTranscriptionService(
      settings.transcriptionService,
      _audioSplitter,
      logSink: logs,
    );
    // A cap only where the whole file must fit one request. Derived from the
    // active profile's model and the audio bitrate rather than fixed, because
    // the binding ceiling moves with both: `gpt-4o-transcribe` truncates at
    // roughly eight minutes, while whisper-1 only has 25 MB to spend — nearly an
    // hour at 64 kbps, half that at 128.
    controller.recordingLimit = _audioSplitter.isAvailable
        ? null
        : TranscriptionLimits.forRequest(
            model: settings.activeProfile?.model,
            audio: settings.audio,
          );
    controller.enrichmentService = settings.enrichmentService;
    // OCR rides the enrichment profile (vision-capable chat endpoint) and has
    // no platform fallback behind it: with no profile active this is the
    // disabled service on desktop exactly as on mobile, so an image capture
    // fails the same readable, retryable way everywhere.
    controller.ocrService = settings.ocrService;
    controller.audioConfig = settings.audio;
    // Same contract as the service swap above: the length reaches the *next*
    // session, never the one already counting down. The alarm is read at zero,
    // so a change there does reach a session already under way.
    timer.configure(settings.timerDuration);
    timer.setAlarmSound(settings.timerAlarm);
    // The one setting that travels *up*: the palette is chosen above
    // `MaterialApp`, which is above this page. A `ValueNotifier` no-ops on an
    // unchanged value, so this costs nothing on the settings changes that are
    // not about the theme.
    widget.themeMode?.value = settings.themeMode;
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
      // No `backgroundColor:` here. That argument is read once, when the
      // sheet opens, and stored on the route — so a theme swapped while the
      // sheet is up would leave its backdrop in the old palette. Omitting it
      // falls through to `BottomSheetThemeData`, which comes off `ThemeData`
      // and therefore follows. Same value, one fewer thing that can lag.
      //
      // Every sheet body is wrapped in `ConsolePaletteScope` for the other
      // half of the same problem: a modal route is a *sibling* of the one the
      // shell's scope covers, so without its own it would keep painting the
      // theme it opened in.
      builder: (BuildContext context) => ConsolePaletteScope(
        builder: (BuildContext context) => TextNoteSheet(),
      ),
    );
    if (body != null && body.trim().isNotEmpty) {
      await controller.addTextNote(body);
    }
  }

  Future<void> _showClipboardHistory(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => ConsolePaletteScope(
        builder: (BuildContext context) => ClipboardHistorySheet(
          watcherService: clipboardWatcher,
          recordingsController: controller,
        ),
      ),
    );
  }

  Future<void> _openCaptureMenu(BuildContext context) async {
    final _CaptureAction? action = await showModalBottomSheet<_CaptureAction>(
      context: context,
      builder: (BuildContext context) => ConsolePaletteScope(
        builder: (BuildContext context) => _CaptureMenuSheet(),
      ),
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
    clipboardWatcher.dispose();
    controller.dispose();
    projects.dispose();
    timer.dispose();
    settings.dispose();
    logs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The palette is put in force *here*, inside the route, and not in
    // `MaterialApp.builder`: that callback never rebuilds the route it already
    // pushed, so activating there leaves the page background following the
    // theme while every card, field and rail keeps the one it was born in.
    // This is also the whole app's single subtree, so one dependency repaints
    // everything.
    return ConsolePaletteScope(
      builder: (BuildContext context) => AnimatedBuilder(
        animation: listenable,
        builder: (BuildContext context, Widget? child) {
          return LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool recording = controller.isRecording;
              final bool compact =
                  constraints.maxWidth < Console.compactBreakpoint;
              // The rail is the *third* form of the shell, not a rename of the
              // desktop one: between the two breakpoints the window is a tablet,
              // where a 216 px column would cost the queue more width than the
              // bottom bar costs it height. Reading the width here — rather than
              // from MediaQuery — is what lets a desktop window dragged narrow
              // fall back through all three, and a widget test pick one by
              // sizing its surface.
              final bool wide = constraints.maxWidth >= Console.railBreakpoint;

              return CelebrationOverlay(
                controller: gamification,
                child: Scaffold(
                  // No AppBar: each tab draws the design's own header (accent eyebrow +
                  // large title) inside its scroll area, so the title scrolls with the
                  // content instead of sitting in a separate bar above it.
                  body: Row(
                    children: <Widget>[
                      // Outside the Stack, so the rail is a sibling of the page
                      // rather than an overlay on it — a capture card must never
                      // scroll under the navigation. It goes with the bottom bar
                      // while recording for the same reason that one does: the
                      // capture screen is single-purpose.
                      if (wide && !recording) _buildRail(),
                      Expanded(
                        child: Stack(
                          children: <Widget>[
                            // IndexedStack so the Queue tab keeps its search text and filter
                            // while the user visits Models/Logs/Config.
                            //
                            // Wrapped here rather than inside each tab: five separate width
                            // caps would drift apart, and the dock below has to agree with
                            // whatever this one is or the record button stops lining up with
                            // the column it captures into.
                            ConsolePageWidth(
                              child: IndexedStack(
                                index: navigationIndex,
                                children: <Widget>[
                                  QueueTab(
                                    controller: controller,
                                    projects: projects,
                                    initialProjectId: activeQueueProjectFilterId,
                                  ),
                                  TimerTab(controller: timer, settings: settings),
                                  ProjectsTab(
                                    controller: projects,
                                    recordingsController: controller,
                                    onNavigateToQueue: (String projectId) {
                                      setState(() {
                                        activeQueueProjectFilterId = projectId;
                                        navigationIndex = queueIndex;
                                      });
                                    },
                                  ),
                                  ClipboardTab(
                                    watcherService: clipboardWatcher,
                                    recordingsController: controller,
                                  ),
                                  ModelsTab(controller: settings),
                                  LogsTab(store: logs),
                                  ConfigTab(
                                    controller: settings,
                                    storagePath: storagePath,
                                    recordingsCount: controller.recordings.length,
                                    logCount: logs.events.length,
                                    onOpenModels: () => setState(
                                      () => navigationIndex = modelsIndex,
                                    ),
                                    // Reported on in the enrichment-context section: which
                                    // file each repository actually contributes, and which
                                    // paths are wrong. The tab never edits them.
                                    projects: projects.projects,
                                    showShortcuts: _isDesktop,
                                    rejectedShortcuts: rejectedShortcuts,
                                    runWithHotkeysSuspended:
                                        _runWithHotkeysSuspended,
                                    // The backfill: every capture taken before a
                                    // vault was configured, copied across on
                                    // demand. The queue is the recordings
                                    // controller's, so the sweep has to be its
                                    // call rather than the settings tab's.
                                    onMirrorAll: controller.mirrorAll,
                                  ),
                                ],
                              ),
                            ),
                            // The compact bar and the rail both carry the capture actions
                            // themselves; only the tablet form in between still needs the
                            // floating dock.
                            if (!compact &&
                                !wide &&
                                navigationIndex == queueIndex &&
                                !recording)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: ConsolePageWidth(
                                  child: CaptureDock(
                                    controller: controller,
                                    onOpenCaptureMenu: () =>
                                        _openCaptureMenu(context),
                                  ),
                                ),
                              ),
                            // Overlaid rather than swapped into the IndexedStack: the Queue
                            // underneath keeps its search text and scroll position for when
                            // the capture finishes.
                            if (recording)
                              Positioned.fill(
                                child: ColoredBox(
                                  color: Console.background,
                                  child: RecordingView(
                                    controller: controller,
                                    projects: projects.projects,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // Hidden while recording — the capture screen is a single-purpose
                  // view, and switching tabs mid-take is not a thing to invite.
                  // Also hidden once the rail is up: five destinations with two
                  // homes on one screen is two navigations.
                  bottomNavigationBar: recording || wide
                      ? null
                      : compact
                      ? CaptureNavBar(
                          destinations: <CaptureNavDestination>[
                            for (
                              int index = 0;
                              index < destinations.length;
                              index++
                            )
                              CaptureNavDestination(
                                icon: destinations[index].icon,
                                label: destinations[index].label,
                                shortLabel: destinations[index].shortLabel,
                                warn:
                                    index == modelsIndex &&
                                    settings.activeProfile == null,
                              ),
                          ],
                          selectedIndex: navigationIndex,
                          onSelected: (int value) =>
                              setState(() => navigationIndex = value),
                          busy: controller.isBusy,
                          onRecord: controller.startRecording,
                          onOpenCaptureMenu: () => _openCaptureMenu(context),
                        )
                      : _buildDesktopNavigationBar(),
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// The wide shell's navigation. Built from the same [destinations] list the
  /// compact bar reads, because the list index *is* [navigationIndex] — two
  /// hand-kept copies would let a reorder in one silently repoint every
  /// `setState(() => navigationIndex = …)` in this file.
  Widget _buildRail() {
    final int total = controller.recordings.length;
    return ConsoleNavRail(
      selectedIndex: navigationIndex,
      onSelected: (int value) => setState(() => navigationIndex = value),
      destinations: <RailDestination>[
        for (int index = 0; index < destinations.length; index++)
          RailDestination(
            icon: destinations[index].icon,
            // The rail has the width for a name rather than an all-caps stub,
            // and a 216 px column of shouting labels reads as a wall.
            label: _titleCase(destinations[index].label),
            // Only the Queue gets a count. A destination showing a bare `0`
            // reads as broken; one with no count reads as a plain link.
            count: index == queueIndex
                ? total
                : index == 3
                    ? clipboardWatcher.items.length
                    : null,
            warn: index == modelsIndex && settings.activeProfile == null,
          ),
      ],
      reviewed: controller.recordings
          .where((Recording item) => item.isProcessedByUser)
          .length,
      total: total,
      busy: controller.isBusy,
      onRecord: controller.startRecording,
      onCapture: () => _openCaptureMenu(context),
    );
  }

  static String _titleCase(String value) =>
      value[0] + value.substring(1).toLowerCase();

  Widget _buildDesktopNavigationBar() {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Console.border)),
      ),
      child: NavigationBar(
        selectedIndex: navigationIndex,
        onDestinationSelected: (int value) {
          setState(() => navigationIndex = value);
        },
        // Built from the same [destinations] list the compact bar and the rail
        // read. It used to be a third, hand-kept copy — which is exactly the
        // shape that lets a destination be added to two of the three forms and
        // silently repoint every index in the file for the one it was not.
        destinations: <NavigationDestination>[
          for (int index = 0; index < destinations.length; index++)
            NavigationDestination(
              icon: index == modelsIndex
                  ? _ProfileBadge(
                      hasActiveProfile: settings.activeProfile != null,
                    )
                  : Icon(destinations[index].icon),
              label: destinations[index].label,
            ),
        ],
      ),
    );
  }
}

/// Amber dot on the Models tab while no provider profile is active, so the
/// "transcription is off" state is visible without opening the tab.
///
/// One icon for both states: the navigation theme already tints it with the accent when
/// selected and dim when not, which is how the design marks the active tab.
class _ProfileBadge extends StatelessWidget {
  const _ProfileBadge({required this.hasActiveProfile});

  final bool hasActiveProfile;

  @override
  Widget build(BuildContext context) {
    const Icon icon = Icon(Icons.memory_rounded);
    if (hasActiveProfile) return icon;

    return Badge(backgroundColor: Console.amber, smallSize: 7, child: icon);
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
      decoration: BoxDecoration(
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
