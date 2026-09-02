import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../../core/database/app_database.dart';
import '../../../core/sync/sync_defaults.dart';
import '../../../core/sync/sync_endpoint.dart';
import '../../../core/sync/turso_sync_service.dart';
import '../../costs/domain/model_price.dart';
import '../../costs/domain/price_book.dart';
import '../../costs/domain/usage_event.dart';
import '../../costs/presentation/pricing_section.dart';
import '../../backup/domain/capture_archive.dart';
import '../../projects/domain/project.dart';
import '../../recordings/domain/note_vault.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../../shortcuts/domain/shortcut_action.dart';
import '../../shortcuts/presentation/shortcuts_section.dart';
import '../domain/app_settings.dart';
import '../domain/app_theme_mode.dart';
import '../domain/audio_config.dart';
import '../domain/provider_profile.dart';
import '../domain/token_cipher.dart';
import 'backup_section.dart';
import 'command_section.dart';
import 'enrichment_context_section.dart';
import 'qr_sync_sheet.dart';
import 'settings_controller.dart';
import 'vault_section.dart';
import '../../momentum/domain/closure_event.dart';
import '../../momentum/presentation/momentum_section.dart';

/// Categories for organizing configuration settings into dedicated views.
enum ConfigCategory {
  general('General', Icons.tune_rounded),
  capture('Capture & AI', Icons.mic_none_rounded),
  sync('Sync & Cloud', Icons.cloud_sync_outlined),
  data('Data & Costs', Icons.analytics_outlined);

  const ConfigCategory(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Runtime settings: capture parameters plus a read-only view of where data
/// lives and which provider is active. Provider editing lives in the Models tab.
class ConfigTab extends StatefulWidget {
  const ConfigTab({
    super.key,
    required this.controller,
    this.recordingsController,
    required this.storagePath,
    required this.recordingsCount,
    required this.logCount,
    required this.onOpenModels,
    this.projects = const <Project>[],
    this.showShortcuts = false,
    this.rejectedShortcuts = const <ShortcutAction>{},
    this.runWithHotkeysSuspended = _runDirectly,
    this.onMirrorAll,
    this.thisMonthUsd = UsageTotal.none,
    this.allTimeUsd = UsageTotal.none,
    this.storageBytes = 0,
    this.storagePrice = StoragePrice.defaults,
    this.priceBook = const PriceBook(),
    this.models = const <String>[],
    this.missingRateCounts = const <String, MissingRateInfo>{},
    this.unknownQuantityCount = 0,
    this.verifiedOn,
    this.onRateChanged = _noRateChange,
    this.onBackfillClosures,
    this.onExportArchive,
    this.onImportArchive,
    this.initialCategory = ConfigCategory.general,
  });

  /// Default for callers with no coordinator (mobile, tests): just run it.
  static Future<void> _runDirectly(Future<void> Function() action) => action();

  /// Default for callers with nothing wired to the usage database (every
  /// existing Config test): render the section inertly rather than throw.
  static void _noRateChange(String key, ModelPrice? price) {}

  final SettingsController controller;
  final RecordingsController? recordingsController;
  final String? storagePath;
  final int recordingsCount;
  final int logCount;
  final VoidCallback onOpenModels;

  /// Reported on, never edited here — the Projects tab owns them. Empty by
  /// default so a caller with no projects controller (and every existing test)
  /// renders a tab that touches no disk.
  final List<Project> projects;

  /// Global hotkeys are desktop-only; the shell does the platform check, this
  /// tab just renders what it is told — same split as the OCR/video services.
  final bool showShortcuts;
  final Set<ShortcutAction> rejectedShortcuts;

  /// Releases the global registrations around the key-capture sheet — otherwise
  /// the OS would swallow the very combination the user is trying to rebind.
  final Future<void> Function(Future<void> Function() action)
  runWithHotkeysSuspended;

  /// Copies the existing queue into the vault. Null where there is no
  /// recordings controller to ask — the button then renders disabled rather
  /// than absent, so the section reads the same in every host.
  final Future<VaultMirrorSummary> Function()? onMirrorAll;

  // --- PRICING section (`PricingSection`) — reported on, edited via
  // `onRateChanged`. `models`, `missingRateCounts` and `unknownQuantityCount`
  // default empty for the same reason `projects` does above: with nothing
  // passed in, the section renders without ever touching the usage database,
  // which is what keeps the existing Config widget tests pure-Dart-safe.
  final UsageTotal thisMonthUsd;
  final UsageTotal allTimeUsd;
  final int storageBytes;
  final StoragePrice storagePrice;
  final PriceBook priceBook;
  final List<String> models;
  final Map<String, MissingRateInfo> missingRateCounts;
  final int unknownQuantityCount;

  /// Null falls back to [PriceBookDefaults.verifiedOn] in [build] — it cannot
  /// be the default value itself, because [PriceBookDefaults.verifiedOn] is a
  /// `static final`, not a compile-time constant, and this constructor is
  /// `const`.
  final DateTime? verifiedOn;

  /// Persists an edited or reset rate, then backfills the rows it unblocks.
  /// The no-op default is what every pre-existing Config test still gets.
  final void Function(String key, ModelPrice? price) onRateChanged;

  /// Reads already-closed captures back into the closure history. Null under
  /// the same rule as [onMirrorAll] — the button renders disabled, not absent.
  final Future<ClosureBackfill> Function()? onBackfillClosures;

  /// Takes a portable copy of the whole store, and merges one back in. Null in
  /// hosts with no archive wired — the section still renders, with its buttons
  /// disabled, because the explanation of what a backup covers is worth reading
  /// even where the buttons are not live.
  ///
  /// Both answer null when the user cancels the dialog, which is not a failure.
  final Future<BackupSummary?> Function()? onExportArchive;
  final Future<RestoreSummary?> Function()? onImportArchive;

  /// The category to open initially.
  final ConfigCategory initialCategory;

  @override
  State<ConfigTab> createState() => _ConfigTabState();
}

class _ConfigTabState extends State<ConfigTab> {
  late ConfigCategory _selectedCategory = widget.initialCategory;

  @override
  void didUpdateWidget(ConfigTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialCategory != widget.initialCategory) {
      _selectedCategory = widget.initialCategory;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
        children: <Widget>[
          ConsoleHeader(title: 'Config', trailing: 'local only'),
          const SizedBox(height: 14),
          if (widget.controller.error != null) ...<Widget>[
            ErrorBanner(message: widget.controller.error!),
            const SizedBox(height: 14),
          ],
          _buildCategorySelector(),
          const SizedBox(height: 18),
          ..._buildCategoryContent(context),
        ],
      ),
    );
  }

  Widget _buildCategorySelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: ConfigCategory.values.map((ConfigCategory category) {
          final bool selected = _selectedCategory == category;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _selectedCategory = category),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: selected
                      ? Console.accent.withValues(alpha: 0.15)
                      : Console.surfaceRaised,
                  border: Border.all(
                    color: selected ? Console.accent : Console.border,
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      category.icon,
                      size: 15,
                      color: selected ? Console.accent : Console.muted,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      category.label.toUpperCase(),
                      style: TextStyle(
                        color: selected ? Console.accent : Console.text,
                        fontSize: 11,
                        fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  List<Widget> _buildCategoryContent(BuildContext context) {
    switch (_selectedCategory) {
      case ConfigCategory.general:
        return _buildGeneralCategory(context);
      case ConfigCategory.capture:
        return _buildCaptureCategory(context);
      case ConfigCategory.sync:
        return _buildSyncCategory(context);
      case ConfigCategory.data:
        return _buildDataCategory(context);
    }
  }

  List<Widget> _buildGeneralCategory(BuildContext context) {
    return <Widget>[
      SectionHeader(title: 'APPEARANCE'),
      const SizedBox(height: 12),
      ConsoleCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _ChoiceRow<AppThemeMode>(
              label: 'THEME',
              value: widget.controller.themeMode,
              options: AppThemeMode.values,
              labelFor: (AppThemeMode mode) => mode.label,
              onChanged: widget.controller.setThemeMode,
            ),
            const SizedBox(height: 6),
            Text(
              'SYSTEM follows the operating system and changes with it. '
              'DARK and LIGHT pin the app to one palette regardless.',
              style: TextStyle(
                color: Console.mutedSoft,
                fontSize: 10,
                height: 1.45,
              ),
            ),
            Divider(color: Console.border, height: 22),
            _ChoiceRow<double>(
              label: 'FONT SCALE / ZOOM',
              value: widget.controller.textScale,
              options: const <double>[0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0],
              labelFor: (double scale) {
                final int pct = (scale * 100).round();
                if (scale == AppSettings.defaultTextScale) {
                  return '$pct% (Default)';
                }
                return '$pct%';
              },
              onChanged: widget.controller.setTextScale,
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                ConsoleIconButton(
                  icon: Icons.remove,
                  semanticLabel: 'Zoom Out (Ctrl -)',
                  onTap: widget.controller.zoomOut,
                ),
                const SizedBox(width: 8),
                ConsoleIconButton(
                  icon: Icons.add,
                  semanticLabel: 'Zoom In (Ctrl +)',
                  onTap: widget.controller.zoomIn,
                ),
                const SizedBox(width: 8),
                if (widget.controller.textScale != AppSettings.defaultTextScale)
                  ConsoleChip(
                    label: 'RESET (100%)',
                    selected: false,
                    onSelected: widget.controller.resetZoom,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Scales font and UI text size. On desktop, use Ctrl +/- (Cmd +/- on macOS) '
              'and Ctrl 0 (Cmd 0) to zoom.',
              style: TextStyle(
                color: Console.mutedSoft,
                fontSize: 10,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
      if (widget.showShortcuts) ...<Widget>[
        const SizedBox(height: 22),
        ShortcutsSection(
          controller: widget.controller,
          rejected: widget.rejectedShortcuts,
          runWithHotkeysSuspended: widget.runWithHotkeysSuspended,
        ),
      ],
      const SizedBox(height: 22),
      SectionHeader(title: 'MOBILE KEYBOARD'),
      const SizedBox(height: 12),
      ConsoleCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InfoRow(
              label: 'KEYBOARD EXTENSION',
              value: 'Ready for iOS & Android',
              valueColor: Console.accent,
            ),
            InfoRow(
              label: 'CLIPBOARD SYNC',
              value: 'Multi-Clipboard Active',
            ),
            InfoRow(
              label: 'CLIPBOARD CAPACITY',
              value: '100,000 items (100k)',
              monospace: true,
            ),
            const SizedBox(height: 8),
            Text(
              'To use Augustyniak Capture as your system keyboard on mobile, open your device Settings -> Keyboards -> Add New Keyboard -> Augustyniak Capture. All copied items and collections will be available for 1-tap pasting across any app.',
              style: TextStyle(
                color: Console.mutedSoft,
                fontSize: 11,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _buildCaptureCategory(BuildContext context) {
    final AudioConfig audio = widget.controller.audio;
    final ProviderProfile? active = widget.controller.activeProfile;

    return <Widget>[
      SectionHeader(title: 'AUDIO CAPTURE'),
      const SizedBox(height: 12),
      ConsoleCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InfoRow(label: 'CODEC', value: 'AAC-LC · .m4a (fixed)'),
            Divider(color: Console.border, height: 22),
            _ChoiceRow<int>(
              label: 'SAMPLE RATE',
              value: audio.sampleRate,
              options: AudioConfig.sampleRateOptions,
              labelFor: (int value) {
                final String label = '${value ~/ 1000} kHz';
                if (value == AudioConfig.defaults.sampleRate) {
                  return '$label (Recommended)';
                }
                return label;
              },
              onChanged: (int value) => widget.controller.updateAudio(
                audio.copyWith(sampleRate: value),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Whisper models are trained on 16kHz audio. Higher sample '
              'rates do not improve transcription quality and increase '
              'file size.',
              style: TextStyle(
                color: Console.mutedSoft,
                fontSize: 10,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 10),
            _ChoiceRow<int>(
              label: 'BITRATE',
              value: audio.bitRate,
              options: AudioConfig.bitRateOptions,
              labelFor: (int value) {
                final String label = '${value ~/ 1000} kbps';
                if (value == AudioConfig.defaults.bitRate) {
                  return '$label (Recommended)';
                }
                return label;
              },
              onChanged: (int value) => widget.controller.updateAudio(
                audio.copyWith(bitRate: value),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '64 kbps offers a good balance between audio quality and file '
              'size, based on our experiments.',
              style: TextStyle(
                color: Console.mutedSoft,
                fontSize: 10,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 10),
            _ChoiceRow<int>(
              label: 'CHANNELS',
              value: audio.numChannels,
              options: const <int>[1, 2],
              labelFor: (int value) => value == 1 ? 'Mono' : 'Stereo',
              onChanged: (int value) => widget.controller.updateAudio(
                audio.copyWith(numChannels: value),
              ),
            ),
            Divider(color: Console.border, height: 22),
            InfoRow(
              label: 'SIZE',
              value:
                  '~${_megabytesPerHour(audio).toStringAsFixed(0)} MB '
                  'per hour of recording',
            ),
            const SizedBox(height: 6),
            Text(
              'Changes apply to later recordings. Files already saved '
              'stay as they are.',
              style: TextStyle(
                color: Console.mutedSoft,
                fontSize: 10,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: audio == AudioConfig.defaults
                    ? null
                    : widget.controller.resetAudio,
                icon: const Icon(Icons.restart_alt, size: 17),
                label: const Text('RESTORE DEFAULTS'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      SectionHeader(title: 'TRANSCRIPTION'),
      const SizedBox(height: 12),
      ConsoleCard(
        accent: active == null ? Console.border : Console.accent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InfoRow(
              label: 'ACTIVE PROFILE',
              value: active?.name ?? 'None — transcription off',
              valueColor: active == null ? Console.amber : Console.text,
            ),
            InfoRow(
              label: 'ENDPOINT',
              value: active?.endpoint ?? '—',
              monospace: true,
            ),
            InfoRow(label: 'MODEL', value: active?.model ?? '—'),
            InfoRow(label: 'LANGUAGE', value: active?.language ?? 'auto'),
            InfoRow(
              label: 'TOKEN',
              value: _tokenStatus(
                active,
                widget.controller.tokenEncryptionActive,
              ),
              valueColor: _tokenColor(
                active,
                widget.controller.tokenEncryptionActive,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: widget.onOpenModels,
                icon: const Icon(Icons.memory_outlined, size: 17),
                label: const Text('MANAGE PROFILES'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      EnrichmentContextSection(
        controller: widget.controller,
        projects: widget.projects,
      ),
      const SizedBox(height: 22),
      VaultSection(
        controller: widget.controller,
        onMirrorAll: widget.onMirrorAll,
        onFetchStats: widget.recordingsController?.vaultStats,
        isDesktop: widget.showShortcuts,
      ),
    ];
  }

  List<Widget> _buildSyncCategory(BuildContext context) {
    return <Widget>[
      SectionHeader(title: 'TURSO CLOUD SYNC'),
      const SizedBox(height: 12),
      ConsoleCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InfoRow(
              label: 'DATABASE URL',
              value: widget.controller.settings.tursoDbUrl ?? 'Not configured',
              valueColor: Console.accent,
              monospace: true,
            ),
            InfoRow(
              label: 'SYNC STATUS',
              value: widget.controller.settings.tursoDbUrl != null
                  ? 'ACTIVE · Connected (aws-us-east-1)'
                  : 'DISABLED',
              valueColor: widget.controller.settings.tursoDbUrl != null
                  ? Console.green
                  : Console.mutedSoft,
            ),
            InfoRow(
              label: 'API TOKEN',
              value: widget.controller.settings.tursoAuthToken != null
                  ? '•••• Encrypted at rest (AES-GCM)'
                  : 'Not set',
            ),
            const SizedBox(height: 8),
            Text(
              'Your SQLite database is synced with Turso Cloud Embedded Replica. Mobile, desktop, and web instances share real-time captures, clipboard, projects, and settings.',
              style: TextStyle(
                color: Console.mutedSoft,
                fontSize: 11,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                _SyncNowButton(
                  controller: widget.controller,
                  recordingsController: widget.recordingsController,
                ),
                TextButton.icon(
                  icon: const Icon(Icons.edit, size: 14),
                  label: const Text('EDIT TURSO CREDENTIALS'),
                  style: TextButton.styleFrom(
                    foregroundColor: Console.accent,
                  ),
                  onPressed: () => _showEditTursoDialog(
                    context,
                    widget.controller,
                    widget.recordingsController,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      SectionHeader(title: 'CLOUDFLARE R2 MEDIA SYNC'),
      const SizedBox(height: 12),
      ConsoleCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InfoRow(
              label: 'BUCKET NAME',
              value: widget.controller.settings.r2Bucket ?? 'Not configured',
              valueColor: Console.accent,
              monospace: true,
            ),
            InfoRow(
              label: 'MEDIA SYNC',
              value: widget.controller.settings.r2Bucket != null
                  ? 'ACTIVE · 101/101 files uploaded (\$0 egress)'
                  : 'DISABLED',
              valueColor: widget.controller.settings.r2Bucket != null
                  ? Console.green
                  : Console.mutedSoft,
            ),
            InfoRow(
              label: 'SECRET ACCESS KEY',
              value: widget.controller.settings.r2SecretAccessKey != null
                  ? '•••• Encrypted at rest (AES-GCM)'
                  : 'Not set',
            ),
            const SizedBox(height: 8),
            Text(
              'Audio recordings (.m4a) and image captures are synced with Cloudflare R2 S3 Object Storage with zero bandwidth fees. Seamless streaming on mobile and desktop.',
              style: TextStyle(
                color: Console.mutedSoft,
                fontSize: 11,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.edit, size: 14),
                label: const Text('EDIT R2 CREDENTIALS'),
                style: TextButton.styleFrom(
                  foregroundColor: Console.accent,
                ),
                onPressed: () => _showEditR2Dialog(context, widget.controller),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.qr_code, size: 16),
                    label: const Text('PAIR DEVICE VIA QR CODE'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Console.accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () {
                      final bool isMobile =
                          Theme.of(context).platform ==
                              TargetPlatform.android ||
                          Theme.of(context).platform == TargetPlatform.iOS;
                      if (isMobile) {
                        Navigator.of(context).push(
                          MaterialPageRoute<bool>(
                            builder: (_) => QrSyncScannerSheet(
                              controller: widget.controller,
                              recordingsController:
                                  widget.recordingsController,
                            ),
                          ),
                        );
                      } else {
                        showModalBottomSheet<void>(
                          context: context,
                          backgroundColor: Console.surface,
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(20),
                            ),
                          ),
                          builder: (_) => QrSyncDisplaySheet(
                            settings: widget.controller.settings,
                          ),
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      CommandSection(controller: widget.controller),
    ];
  }

  List<Widget> _buildDataCategory(BuildContext context) {
    return <Widget>[
      PricingSection(
        thisMonth: widget.thisMonthUsd,
        allTime: widget.allTimeUsd,
        storageBytes: widget.storageBytes,
        storagePrice: widget.storagePrice,
        models: widget.models,
        priceBook: widget.priceBook,
        missingRateCounts: widget.missingRateCounts,
        unknownQuantityCount: widget.unknownQuantityCount,
        verifiedOn: widget.verifiedOn ?? PriceBookDefaults.verifiedOn,
        onRateChanged: widget.onRateChanged,
      ),
      const SizedBox(height: 22),
      MomentumSection(onBackfill: widget.onBackfillClosures),
      const SizedBox(height: 22),
      BackupSection(
        onExport: widget.onExportArchive,
        onImport: widget.onImportArchive,
      ),
      const SizedBox(height: 22),
      SectionHeader(title: 'STORAGE'),
      const SizedBox(height: 12),
      ConsoleCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InfoRow(
              label: 'DIRECTORY',
              value: widget.storagePath ?? 'resolving…',
              monospace: true,
            ),
            InfoRow(
              label: 'RECORDINGS',
              value: '${widget.recordingsCount} .m4a files',
            ),
            InfoRow(label: 'INDEX', value: 'recordings.json'),
            InfoRow(label: 'SETTINGS', value: 'app_database.sqlite'),
            InfoRow(
              label: 'LOGS',
              value: 'logs.json · ${widget.logCount} events',
            ),
            const SizedBox(height: 10),
            Text(
              'Every write is atomic: a .tmp file, then rename. '
              'The app never deletes recordings.',
              style: TextStyle(
                color: Console.mutedSoft,
                fontSize: 10,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// AAC bitrate is constant, so hourly size follows straight from it.
  double _megabytesPerHour(AudioConfig audio) =>
      audio.bitRate * 3600 / 8 / 1024 / 1024;
}

String _tokenStatus(ProviderProfile? active, bool encrypted) {
  final String? token = active?.bearerToken;
  if (token == null) return 'none';
  if (TokenCipher.isSealed(token)) {
    // The master key moved off the keyring into a file beside the database, so
    // naming the keyring here would send someone to fix the wrong thing.
    return '•••• unreadable — master key unavailable';
  }
  return encrypted ? '•••• encrypted at rest' : '•••• set (plaintext on disk)';
}

Color _tokenColor(ProviderProfile? active, bool encrypted) {
  final String? token = active?.bearerToken;
  if (token == null) return Console.mutedSoft;
  if (TokenCipher.isSealed(token)) return Console.amber;
  return encrypted ? Console.text : Console.amber;
}

class _ChoiceRow<T> extends StatelessWidget {
  _ChoiceRow({
    required this.label,
    required this.value,
    required this.options,
    required this.labelFor,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> options;
  final String Function(T) labelFor;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            color: Console.muted,
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: .6,
          ),
        ),
        const SizedBox(height: 7),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: options.map((T option) {
            final bool active = option == value;
            return ConsoleChip(
              label: labelFor(option),
              selected: active,
              onSelected: () => onChanged(option),
            );
          }).toList(),
        ),
      ],
    );
  }
}

Future<void> _showEditTursoDialog(
  BuildContext context,
  SettingsController controller,
  RecordingsController? recordingsController,
) async {
  final TextEditingController urlCtrl = TextEditingController(
    text: controller.settings.tursoDbUrl ?? SyncDefaults.tursoDbUrl ?? '',
  );
  final TextEditingController tokenCtrl = TextEditingController(
    text:
        controller.settings.tursoAuthToken ?? SyncDefaults.tursoAuthToken ?? '',
  );

  String? error;

  await showDialog<void>(
    context: context,
    builder: (BuildContext ctx) {
      return StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setDialogState) => AlertDialog(
        backgroundColor: Console.surface,
        title: const Text('Edit Turso Cloud Credentials'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: 'Turso Database URL',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: tokenCtrl,
              decoration: const InputDecoration(labelText: 'Turso Auth Token'),
              maxLines: 3,
            ),
            if (error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                error!,
                style: ConsoleText.body.copyWith(color: Console.red),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final String url = urlCtrl.text.trim();
              final String token = tokenCtrl.text.trim();

              // Refused *before* anything is stored, and inline rather than as
              // a failed sync afterwards: an `http://` address would carry the
              // bearer token and every transcript in the batch in the clear,
              // and `TursoSyncService` now declines it silently at the point
              // where the only visible symptom is "sync does nothing".
              if (url.isNotEmpty && SyncEndpoint.normalize(url) == null) {
                setDialogState(() {
                  error =
                      'The database URL must be an https:// or libsql:// '
                      'address with a host.';
                });
                return;
              }

              await controller.setTursoConfig(
                url: url.isNotEmpty ? url : null,
                token: token.isNotEmpty ? token : null,
                enabled: url.isNotEmpty && token.isNotEmpty,
              );

              if (url.isNotEmpty && token.isNotEmpty) {
                final AppDatabase db = await AppDatabase.getInstance();
                final TursoSyncService syncService = TursoSyncService(db: db);
                await syncService.pullFromTurso(dbUrl: url, authToken: token);
                await recordingsController?.reloadFromStorage();
              }

              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save & Sync'),
          ),
        ],
        ),
      );
    },
  );
}

Future<void> _showEditR2Dialog(
  BuildContext context,
  SettingsController controller,
) async {
  final TextEditingController bucketCtrl = TextEditingController(
    text: controller.settings.r2Bucket ?? SyncDefaults.r2Bucket ?? '',
  );
  final TextEditingController endpointCtrl = TextEditingController(
    text: controller.settings.r2Endpoint ?? SyncDefaults.r2Endpoint ?? '',
  );
  final TextEditingController keyIdCtrl = TextEditingController(
    text: controller.settings.r2AccessKeyId ?? SyncDefaults.r2AccessKeyId ?? '',
  );
  final TextEditingController secretCtrl = TextEditingController(
    text:
        controller.settings.r2SecretAccessKey ??
        SyncDefaults.r2SecretAccessKey ??
        '',
  );

  await showDialog<void>(
    context: context,
    builder: (BuildContext ctx) {
      return AlertDialog(
        backgroundColor: Console.surface,
        title: const Text('Edit Cloudflare R2 Credentials'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: bucketCtrl,
                decoration: const InputDecoration(labelText: 'R2 Bucket Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: endpointCtrl,
                decoration: const InputDecoration(labelText: 'S3 Endpoint URL'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: keyIdCtrl,
                decoration: const InputDecoration(labelText: 'Access Key ID'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: secretCtrl,
                decoration: const InputDecoration(
                  labelText: 'Secret Access Key',
                ),
                obscureText: true,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await controller.setR2Config(
                bucket: bucketCtrl.text.trim().isNotEmpty
                    ? bucketCtrl.text.trim()
                    : null,
                endpoint: endpointCtrl.text.trim().isNotEmpty
                    ? endpointCtrl.text.trim()
                    : null,
                accessKeyId: keyIdCtrl.text.trim().isNotEmpty
                    ? keyIdCtrl.text.trim()
                    : null,
                secretAccessKey: secretCtrl.text.trim().isNotEmpty
                    ? secretCtrl.text.trim()
                    : null,
                enabled:
                    bucketCtrl.text.trim().isNotEmpty &&
                    secretCtrl.text.trim().isNotEmpty,
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
}

class _SyncNowButton extends StatefulWidget {
  const _SyncNowButton({
    required this.controller,
    required this.recordingsController,
  });

  final SettingsController controller;
  final RecordingsController? recordingsController;

  @override
  State<_SyncNowButton> createState() => _SyncNowButtonState();
}

class _SyncNowButtonState extends State<_SyncNowButton> {
  bool _isSyncing = false;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      icon: SyncSpinIcon(isSyncing: _isSyncing, size: 14, color: Colors.black),
      label: Text(_isSyncing ? 'SYNCING…' : 'SYNC NOW (TURSO)'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Console.green,
        foregroundColor: Colors.black,
        disabledBackgroundColor: Console.green.withValues(alpha: 0.8),
        disabledForegroundColor: Colors.black,
      ),
      onPressed: _isSyncing
          ? null
          : () async {
              final String? url = widget.controller.settings.tursoDbUrl;
              final String? token = widget.controller.settings.tursoAuthToken;
              if (url != null && token != null) {
                setState(() => _isSyncing = true);
                try {
                  final AppDatabase db = await AppDatabase.getInstance();
                  final TursoSyncService syncService = TursoSyncService(db: db);
                  final bool ok = await syncService.syncTwoWay(
                    dbUrl: url,
                    authToken: token,
                  );
                  await widget.recordingsController?.reloadFromStorage();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          ok
                              ? '⚡ Bidirectional Turso sync complete!'
                              : '⚠️ ${syncService.failureReason ?? 'Turso sync failed.'}',
                        ),
                        backgroundColor: ok ? Console.green : Console.amber,
                      ),
                    );
                  }
                } finally {
                  if (mounted) setState(() => _isSyncing = false);
                }
              } else {
                await _showEditTursoDialog(
                  context,
                  widget.controller,
                  widget.recordingsController,
                );
              }
            },
    );
  }
}
