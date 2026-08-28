import 'dart:async';
import 'dart:io';

// `setEquals` lives in foundation and is NOT among the handful of symbols
// material re-exports from it.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../app/ui_kit.dart';
import '../../../core/database/app_database.dart';
import '../../backup/data/file_picker_archive_location.dart';
import '../../backup/data/zip_capture_archive.dart';
import '../../backup/domain/capture_archive.dart';
import '../../backup/presentation/backup_coordinator.dart';
import '../../clipboard/domain/clipboard_watcher_service.dart';
import '../../clipboard/presentation/clipboard_history_sheet.dart';
import '../../clipboard/presentation/clipboard_tab.dart';
import '../../costs/data/recording_usage_sink.dart';
import '../../costs/data/usage_repository.dart';
import '../../costs/domain/model_price.dart';
import '../../costs/domain/price_book.dart';
import '../../costs/domain/usage_event.dart';
import '../../costs/domain/usage_model_keys.dart';
import '../../enrichment/data/composed_enrichment_context_source.dart';
import '../../logs/data/log_store.dart';
import '../../logs/domain/log_event.dart';
import '../../logs/presentation/logs_tab.dart';
import '../../processing/data/native_media_processor.dart';
import '../../processing/data/video_audio_extractor.dart';
import '../../processing/data/video_poster_extractor.dart';
import '../../projects/data/terminal_launcher.dart';
import '../../projects/data/zellij_agent_session_launcher.dart';
import '../../projects/data/projects_repository.dart';
import '../../projects/domain/agent_session_launcher.dart';
import '../../projects/domain/project.dart';
import '../../settings/data/aes_gcm_token_cipher.dart';
import '../../settings/data/file_master_key_store.dart';
import '../../settings/data/migrating_master_key_store.dart';
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
import '../../momentum/data/file_closure_log.dart';
import '../../momentum/data/notifying_closure_log.dart';
import '../../momentum/domain/closure_event.dart';
import '../../momentum/presentation/momentum_controller.dart';
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
import '../data/foreground_capture_session.dart';
import '../data/markdown_note_vault.dart';
import '../domain/capture_session.dart';
import '../data/project_agent_handoff.dart';
import '../data/command_router.dart';
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

class _RecordingsPageState extends State<RecordingsPage>
    with WidgetsBindingObserver {
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

  /// Null until `_bootstrap()` opens the database — the shell builds its
  /// controllers synchronously in `initState`, so the very first captures on
  /// a cold start can race the database open. `usageSink` reads this through
  /// a resolver rather than capturing it, and drops an event rather than
  /// throwing while it is still null.
  UsageRepository? _usageRepository;
  late final RecordingUsageSink usageSink;
  late final SettingsController settings;
  late final LogStore logs;
  late final GamificationController gamification;
  late final RecordingsController controller;
  late final ProjectsController projects;
  late final FocusTimerController timer;

  /// How much has been finished lately. The counterpart to
  /// [GamificationController], not a replacement: that one counts lifetime
  /// totals and unlocks milestones, this one answers "how is it going lately",
  /// which needs dated events a cumulative counter cannot be run backwards into.
  late final MomentumController momentum;
  late final ShortcutsCoordinator shortcuts;
  late final ClipboardWatcherService clipboardWatcher;
  late final BackupCoordinator backup;
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

  /// The pre-keyring key file: read once so its key can be handed to the
  /// keyring, then deleted. One instance, because the same object is both
  /// the fallback that is read and the copy that is retired.
  final FileMasterKeyStore _legacyKeyFile = FileMasterKeyStore();

  @override
  void initState() {
    super.initState();
    // The other of the two moments Command outcomes are read back — see
    // `refreshCommandOutcomes`. Coming to the foreground is when somebody is
    // actually looking; a timer would spend battery when nobody is.
    WidgetsBinding.instance.addObserver(this);
    logs = LogStore(archive: FileLogArchive());
    // Built once and shared by the settings and recordings controllers: both
    // sides of a job — the HTTP call the settings-built service makes, and
    // the beginJob/endJob scope the recordings controller wraps it in — must
    // land on the same sink instance. Read the repository through a resolver
    // rather than capturing it, because it does not exist yet: the database
    // opens asynchronously in `_bootstrap()`, well after this constructor
    // runs.
    usageSink = RecordingUsageSink(
      repository: () => _usageRepository,
      // Read per call so a rate edited in the Config tab reaches the next
      // capture with nothing to rebuild.
      priceBook: () => PriceBook(overrides: settings.settings.priceOverrides),
      logSink: logs,
    );
    settings = SettingsController(
      repository: SettingsRepository(
        // The keyring is the primary store, and the key file beside the
        // database is the copy it takes over from and then deletes.
        //
        // The file existed because the keychain ACL names apps by code
        // signature and ad-hoc rebuilds each produced a new one, so a fresh
        // build was a stranger to the entry it wrote yesterday. That is fixed
        // at the source now — LOCAL_SIGN_IDENTITY gives the app a designated
        // requirement bound to a certificate rather than to a binary hash, so
        // it survives rebuilds and is shared across worktrees. With the reason
        // gone, keeping the key next to the ciphertext it opens buys nothing
        // and costs the protection encryption is for.
        //
        // MigratingMasterKeyStore retires the file only after the keyring
        // hands the same key back, and lets a refusing keyring throw rather
        // than answering from the file — the failure has to be visible, not
        // papered over by the store this is migrating away from.
        cipher: AesGcmTokenCipher(
          keyStore: MigratingMasterKeyStore(
            primary: const SecureStorageMasterKeyStore(),
            fallback: _legacyKeyFile,
            retireFallback: _legacyKeyFile.delete,
          ),
        ),
      ),
      usageSink: usageSink,
    );
    gamification = GamificationController();
    // One launcher, two entry points: the project card starts a session with no
    // task in hand, the queue starts one on a capture. Sharing the instance is
    // what keeps them landing in the same named session rather than opening a
    // second agent on the same repository.
    // Asked of `TerminalLauncher` rather than of `Platform`, because that is
    // where the answer is decided: macOS and Linux both drive Zellij and differ
    // only in how a window is opened. A null launcher hides the queue's agent
    // button entirely, so this predicate and the one picking an implementation
    // must not be able to disagree.
    final AgentSessionLauncher? launcher = TerminalLauncher.isSupportedPlatform
        ? ZellijAgentSessionLauncher()
        : null;
    projects = ProjectsController(
      repository: ProjectsRepository(),
      launcher: launcher,
    );
    // Handed the same repositories the app is already using, so an export is a
    // copy of the live store rather than of a second reading of it.
    backup = BackupCoordinator(
      archive: ZipCaptureArchive(
        directoryProvider: repository.recordingsDirectory,
        recordings: repository,
        projects: ProjectsRepository(),
      ),
      picker: const FilePickerArchiveLocation(),
      logSink: logs,
    );
    controller = RecordingsController(
      repository: repository,
      gamificationController: gamification,
      // The durable record of what was finished, one appended line per capture.
      // Deliberately not derived from `recordings.json`: that index is
      // rewritten wholesale and shrinks on delete, so a history read from it
      // would be silently rewritten by a deletion.
      //
      // Wrapped so the panel hears about each closure as it lands. Without it
      // the count would hold whatever was read at start-up and only catch up on
      // the next launch — stale for the whole session, which is the least
      // trustworthy state a counter can be in.
      closureLog: NotifyingClosureLog(
        const FileClosureLog(),
        (ClosureEvent event) => momentum.noteClosure(event),
      ),
      projectById: _projectById,
      vaultDirectory: () =>
          settings.vaultPath == null || settings.vaultPath!.trim().isEmpty
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
      // A bound project sends `agentTask` to the control plane and everything
      // else to its own inbox; an unbound one behaves exactly as it did before
      // Command existed. One decision point, so no surface has to repeat it.
      commandClient: settings.commandClient,
      // Read live rather than captured, on the same rule as the vault's
      // directory: the address can change in Config at any moment and the next
      // tap on an outcome must follow it.
      commandBaseUrl: () => settings.settings.commandBaseUrl,
      captureRouter: ProjectCaptureRouter(
        command: CommandRouter(
          projectById: _projectById,
          // Read off the settings controller rather than captured, like every
          // other service here: an address edited in Config reaches the next
          // delivery without rebuilding the page.
          client: settings.commandClient,
        ),
        fallback: ProjectInboxRouter(projectById: _projectById),
      ),
      // The queue's other way out: a capture becomes an agent's opening task.
      // Disabled wherever no launcher exists, which hides the control rather
      // than offering one that can only fail.
      agentHandoff: launcher == null
          ? const DisabledAgentHandoff()
          : ProjectAgentHandoff(projectById: _projectById, launcher: launcher),
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
      // Brackets the processor and enrichment calls that make up each job, so
      // every event the settings-built services emit lands against the
      // capture that caused it. Same instance the settings controller was
      // given above — the two sides of one job must share a sink.
      usageSink: usageSink,
      // Finished processor output lands on the system clipboard, so a clipboard
      // manager keeps it in history. Tests get the no-op default instead.
      clipboardSink: const SystemClipboardSink(),
      // Video plays in whatever the platform already uses for it; tests get the
      // no-op default.
      mediaOpener: const SystemMediaOpener(),
      // **Android only.** Its microphone access is "while-in-use", so without a
      // foreground service the input is cut the moment the activity stops being
      // visible — a locked screen ended the capture and nothing reported it.
      // iOS needs no counterpart: `record_ios` already activates a
      // `.playAndRecord` session, so the whole of background recording there is
      // the `UIBackgroundModes: audio` key in `Info.plist`. Every desktop keeps
      // its microphone in the background and gets the no-op default.
      captureSession: Platform.isAndroid
          ? const ForegroundCaptureSession()
          : const NoopCaptureSession(),
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
    // Reads the same log the controller appends to, plus the timer's sessions
    // through a callback rather than a second `FocusSessionLog` — no repeated
    // read of that file, and a session that has just finished is visible at
    // once. It never writes there: `_record()` firing only from `_finish()` is
    // the one reason "a pomodoro" means exactly one thing.
    momentum = MomentumController(
      log: const FileClosureLog(),
      sessions: () => timer.sessions,
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
      momentum,
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

  /// Import, then re-read what the import wrote.
  ///
  /// The merge happens at the repository layer, underneath the controller's
  /// in-memory list — deliberately, because that is where the "existing row
  /// wins" rule can be enforced against the file rather than against whatever
  /// the UI currently holds. The cost is that the queue on screen is stale the
  /// instant it succeeds, so the reload is part of the operation and not a
  /// refresh the user has to think of. Projects come back first: a restored
  /// capture may carry a `projectId` that only the imported list explains.
  Future<RestoreSummary?> _importArchive() async {
    final RestoreSummary? summary = await backup.import();
    if (summary == null) return null;
    await projects.initialize();
    await controller.initialize();
    // Sources can arrive without their rows — an archive whose index was
    // unreadable still restores its files — and this is what walks them back
    // into the queue instead of leaving them invisible on disk.
    await controller.recoverOrphans();
    if (mounted) _applyActiveProject();
    return summary;
  }

  Future<void> _bootstrap() async {
    await logs.initialize();
    // Opens (or creates) the SQLite database `usageSink` writes cost rows
    // into. Before this resolves, `_usageRepository` is null and the sink
    // drops whatever it is asked to record — see `RecordingUsageSink`. Ahead
    // of `settings.initialize()` so a capture started the instant settings
    // finish loading still has somewhere to bill.
    //
    // Guarded like every other store this method opens (settings, projects,
    // logs all catch their own failures into an error banner): cost
    // accounting is best-effort by design, so a database that will not open
    // — an unwritable app-support directory, a locked or corrupt file — must
    // cost the cost history, never the rest of start-up. An unguarded throw
    // here would abort the whole of `_bootstrap()` with no error banner at
    // all, which is the exact failure this feature is built never to cause.
    try {
      _usageRepository = UsageRepository(
        (await AppDatabase.getInstance()).rawDb,
      );
    } catch (exception) {
      logs.log('Cost store unavailable: $exception', level: LogLevel.warn);
    }
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
    // Both read real files, so they belong here for the same reason
    // `recoverOrphans` does: an in-memory repository fake cannot stand in for
    // them, and running either from `initialize` would send every widget test
    // to the developer's own disk.
    await controller.loadClosures();
    await momentum.initialize();
    // Explicit rather than relying on the notification `initialize` emits, so
    // the hotkeys are guaranteed live once bootstrap returns.
    await _applyShortcuts();

    final Directory directory = await repository.recordingsDirectory();
    if (!mounted) return;
    setState(() => storagePath = directory.path);
  }

  /// The distinct model/provider keys the Config tab's PRICING section
  /// offers a rate row for. Deliberately not `PriceBookDefaults.rates.keys`:
  /// that is the whole shipped catalogue, and an install that only ever
  /// talks to one provider does not need three dozen rows for models it has
  /// never called.
  ///
  /// Union of usage history **and** the user's configured profiles — see
  /// [usageModelKeys]. The profile half does not depend on
  /// `_usageRepository`, which is why it is read here rather than folded
  /// into the `repository == null` early return the way the old
  /// history-only version was: a database that never opened must not cost
  /// the user every rate row, only the ones history would have added.
  List<String> _usageModels() {
    final UsageRepository? repository = _usageRepository;
    return usageModelKeys(
      events: repository?.all() ?? const <UsageEvent>[],
      profiles: settings.settings.profiles,
    );
  }

  /// Persists an edited or reset rate, then reprices whatever it unblocks.
  ///
  /// One action, not two: a rate typed for a model that already has rows
  /// sitting unpriced for `noRate` is worthless left as a rate nobody applied
  /// to the history that motivated typing it. `backfill` only ever touches
  /// rows with no cost yet, so it cannot rewrite a price already charged
  /// against an earlier rate.
  void _onPriceRateChanged(String key, ModelPrice? price) {
    unawaited(() async {
      await settings.setPriceOverride(key, price);
      if (price == null) return;
      final UsageRepository? repository = _usageRepository;
      if (repository == null) return;
      final int filled = repository.backfill(
        key,
        PriceBook(overrides: settings.settings.priceOverrides),
      );
      if (filled > 0 && mounted) setState(() {});
    }());
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      unawaited(controller.refreshCommandOutcomes());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    momentum.dispose();
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
                                    initialProjectId:
                                        activeQueueProjectFilterId,
                                    // The amber dot on the Models destination
                                    // already says this, but it says it where
                                    // nobody on a first run is looking. The
                                    // queue is the screen the app opens on and
                                    // the one an unconfigured install leaves
                                    // empty, so the prompt belongs there too.
                                    hasTranscriptionProfile:
                                        settings.activeProfile != null,
                                    onConfigureModels: () => setState(
                                      () => navigationIndex = modelsIndex,
                                    ),
                                    // Null until `_bootstrap()`'s database open
                                    // resolves — same nullable resolver shape
                                    // the PRICING section below already reads
                                    // through.
                                    usageRepository: _usageRepository,
                                    storagePrice: settings.storagePrice,
                                  ),
                                  TimerTab(
                                    controller: timer,
                                    settings: settings,
                                    momentum: momentum,
                                  ),
                                  ProjectsTab(
                                    controller: projects,
                                    recordingsController: controller,
                                    // Read off the settings controller rather
                                    // than held, on the same rule as the
                                    // transcription and enrichment services:
                                    // an address edited in Config reaches the
                                    // next binding without rebuilding the tab.
                                    commandClient: settings.commandClient,
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
                                    recordingsController: controller,
                                    storagePath: storagePath,
                                    recordingsCount:
                                        controller.recordings.length,
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
                                    // PRICING section. `_usageRepository` is
                                    // null until `_bootstrap()`'s database
                                    // open resolves, so every read here falls
                                    // back to the same "nothing yet" value the
                                    // section would show on a fresh install.
                                    thisMonthUsd:
                                        _usageRepository?.totalSince(
                                          DateTime(
                                            DateTime.now().year,
                                            DateTime.now().month,
                                          ),
                                        ) ??
                                        UsageTotal.none,
                                    allTimeUsd:
                                        _usageRepository?.totalAll() ??
                                        UsageTotal.none,
                                    // Both R2 (source files) and Turso (the
                                    // index) scale with the same total, so one
                                    // measured sum feeds both halves of the
                                    // monthly-rate formula.
                                    storageBytes: controller.recordings
                                        .fold<int>(
                                          0,
                                          (int sum, Recording r) =>
                                              sum + r.sizeBytes,
                                        ),
                                    storagePrice: settings.storagePrice,
                                    priceBook: PriceBook(
                                      overrides:
                                          settings.settings.priceOverrides,
                                    ),
                                    models: _usageModels(),
                                    missingRateCounts:
                                        _usageRepository?.missingRateCounts() ??
                                        const <String, MissingRateInfo>{},
                                    unknownQuantityCount:
                                        _usageRepository
                                            ?.unknownQuantityCount() ??
                                        0,
                                    onRateChanged: _onPriceRateChanged,
                                    onBackfillClosures:
                                        controller.backfillClosures,
                                    onExportArchive: backup.export,
                                    onImportArchive: _importArchive,
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
                          onRecord: _startRecording,
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

  /// Starts a capture from the Queue, whichever tab the button was pressed on.
  ///
  /// The same rule the hotkey path follows (`ShortcutsCoordinator`'s
  /// `revealQueue`), and for the same reason: the Queue is the only tab that
  /// renders `controller.error`. The capture screen overlays whatever is showing
  /// and then closes itself on the way out — so a save that fails after it
  /// closes reports into an `IndexedStack` layer nobody is looking at, and the
  /// recording is simply gone with no signal at all. The compact bar and the
  /// rail are both reachable from every tab, which is what made this possible;
  /// the floating dock never was, because it is only mounted on the Queue.
  ///
  /// Revealed *before* starting rather than after. The hotkey path is the other
  /// way round — deliberately, because raising the window costs a
  /// window-manager round trip and a record hotkey that spends it first loses
  /// the opening word. A `setState` costs nothing, so there is no word to lose
  /// here, and going first means the reveal still holds if `startRecording`
  /// throws.
  Future<void> _startRecording() async {
    if (navigationIndex != queueIndex) {
      setState(() => navigationIndex = queueIndex);
    }
    await controller.startRecording();
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
      onRecord: _startRecording,
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
