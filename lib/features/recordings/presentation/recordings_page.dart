import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../logs/data/log_store.dart';
import '../../logs/presentation/logs_tab.dart';
import '../../settings/presentation/config_tab.dart';
import '../../settings/presentation/models_tab.dart';
import '../../settings/presentation/settings_controller.dart';
import '../../transcription/data/transcription_service.dart';
import '../data/recordings_repository.dart';
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
      logSink: logs,
    );

    settings.addListener(_applySettings);
    listenable = Listenable.merge(<Listenable>[controller, settings, logs]);
    _bootstrap();
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
              ? RecordButton(controller: controller)
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
