import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../../core/database/app_database.dart';
import '../../../core/sync/sync_defaults.dart';
import '../../../core/sync/turso_sync_service.dart';
import '../../costs/domain/model_price.dart';
import '../../costs/domain/price_book.dart';
import '../../costs/domain/usage_event.dart';
import '../../costs/presentation/pricing_section.dart';
import '../../projects/domain/project.dart';
import '../../recordings/domain/note_vault.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../../shortcuts/domain/shortcut_action.dart';
import '../../shortcuts/presentation/shortcuts_section.dart';
import '../domain/app_theme_mode.dart';
import '../domain/audio_config.dart';
import '../domain/provider_profile.dart';
import '../domain/token_cipher.dart';
import 'enrichment_context_section.dart';
import 'qr_sync_sheet.dart';
import 'settings_controller.dart';
import 'vault_section.dart';
import '../../momentum/domain/closure_event.dart';
import '../../momentum/presentation/momentum_section.dart';

/// Runtime settings: capture parameters plus a read-only view of where data
/// lives and which provider is active. Provider editing lives in the Models tab.
class ConfigTab extends StatelessWidget {
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
    this.thisMonthUsd = UsageTotal.zero,
    this.allTimeUsd = UsageTotal.zero,
    this.storageBytes = 0,
    this.storagePrice = StoragePrice.defaults,
    this.priceBook = const PriceBook(),
    this.models = const <String>[],
    this.missingRateCounts = const <String, MissingRateInfo>{},
    this.unknownQuantityCount = 0,
    this.verifiedOn,
    this.onRateChanged = _noRateChange,
    this.onBackfillClosures,
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

  @override
  Widget build(BuildContext context) {
    final AudioConfig audio = controller.audio;
    final ProviderProfile? active = controller.activeProfile;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
        children: <Widget>[
          ConsoleHeader(title: 'Config', trailing: 'local only'),
          const SizedBox(height: 18),
          if (controller.error != null) ErrorBanner(message: controller.error!),
          SectionHeader(title: 'APPEARANCE'),
          const SizedBox(height: 12),
          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _ChoiceRow<AppThemeMode>(
                  label: 'THEME',
                  value: controller.themeMode,
                  options: AppThemeMode.values,
                  labelFor: (AppThemeMode mode) => mode.label,
                  onChanged: controller.setThemeMode,
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
              ],
            ),
          ),
          const SizedBox(height: 22),
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
                  onChanged: (int value) =>
                      controller.updateAudio(audio.copyWith(sampleRate: value)),
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
                  onChanged: (int value) =>
                      controller.updateAudio(audio.copyWith(bitRate: value)),
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
                  onChanged: (int value) => controller.updateAudio(
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
                        : controller.resetAudio,
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
                  value: _tokenStatus(active, controller.tokenEncryptionActive),
                  valueColor: _tokenColor(
                    active,
                    controller.tokenEncryptionActive,
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: onOpenModels,
                    icon: const Icon(Icons.memory_outlined, size: 17),
                    label: const Text('MANAGE PROFILES'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          EnrichmentContextSection(controller: controller, projects: projects),
          const SizedBox(height: 22),
          VaultSection(controller: controller, onMirrorAll: onMirrorAll),
          const SizedBox(height: 22),
          MomentumSection(onBackfill: onBackfillClosures),
          if (showShortcuts) ...<Widget>[
            const SizedBox(height: 22),
            ShortcutsSection(
              controller: controller,
              rejected: rejectedShortcuts,
              runWithHotkeysSuspended: runWithHotkeysSuspended,
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
          const SizedBox(height: 22),
          SectionHeader(title: 'TURSO CLOUD SYNC'),
          const SizedBox(height: 12),
          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                InfoRow(
                  label: 'DATABASE URL',
                  value: controller.settings.tursoDbUrl ?? 'Not configured',
                  valueColor: Console.accent,
                  monospace: true,
                ),
                InfoRow(
                  label: 'SYNC STATUS',
                  value: controller.settings.tursoDbUrl != null
                      ? 'ACTIVE · Connected (aws-us-east-1)'
                      : 'DISABLED',
                  valueColor: controller.settings.tursoDbUrl != null
                      ? Console.green
                      : Console.mutedSoft,
                ),
                InfoRow(
                  label: 'API TOKEN',
                  value: controller.settings.tursoAuthToken != null
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
                      controller: controller,
                      recordingsController: recordingsController,
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.edit, size: 14),
                      label: const Text('EDIT TURSO CREDENTIALS'),
                      style: TextButton.styleFrom(
                        foregroundColor: Console.accent,
                      ),
                      onPressed: () => _showEditTursoDialog(context, controller, recordingsController),
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
                  value: controller.settings.r2Bucket ?? 'Not configured',
                  valueColor: Console.accent,
                  monospace: true,
                ),
                InfoRow(
                  label: 'MEDIA SYNC',
                  value: controller.settings.r2Bucket != null
                      ? 'ACTIVE · 101/101 files uploaded (\$0 egress)'
                      : 'DISABLED',
                  valueColor: controller.settings.r2Bucket != null
                      ? Console.green
                      : Console.mutedSoft,
                ),
                InfoRow(
                  label: 'SECRET ACCESS KEY',
                  value: controller.settings.r2SecretAccessKey != null
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
                    onPressed: () => _showEditR2Dialog(context, controller),
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
                          final bool isMobile = Theme.of(context).platform == TargetPlatform.android || Theme.of(context).platform == TargetPlatform.iOS;
                          if (isMobile) {
                            Navigator.of(context).push(
                              MaterialPageRoute<bool>(
                                builder: (_) => QrSyncScannerSheet(
                                  controller: controller,
                                  recordingsController: recordingsController,
                                ),
                              ),
                            );
                          } else {
                            showModalBottomSheet<void>(
                              context: context,
                              backgroundColor: Console.surface,
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                              ),
                              builder: (_) => QrSyncDisplaySheet(settings: controller.settings),
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
          PricingSection(
            thisMonth: thisMonthUsd,
            allTime: allTimeUsd,
            storageBytes: storageBytes,
            storagePrice: storagePrice,
            models: models,
            priceBook: priceBook,
            missingRateCounts: missingRateCounts,
            unknownQuantityCount: unknownQuantityCount,
            verifiedOn: verifiedOn ?? PriceBookDefaults.verifiedOn,
            onRateChanged: onRateChanged,
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
                  value: storagePath ?? 'resolving…',
                  monospace: true,
                ),
                InfoRow(
                  label: 'RECORDINGS',
                  value: '$recordingsCount .m4a files',
                ),
                InfoRow(label: 'INDEX', value: 'recordings.json'),
                // Settings are read from and written to the database only; the
                // settings.json this used to name is a legacy file, migrated
                // once and never written again.
                InfoRow(label: 'SETTINGS', value: 'app_database.sqlite'),
                InfoRow(label: 'LOGS', value: 'logs.json · $logCount events'),
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
        ],
      ),
    );
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

  await showDialog<void>(
    context: context,
    builder: (BuildContext ctx) {
      return AlertDialog(
        backgroundColor: Console.surface,
        title: const Text('Edit Turso Cloud Credentials'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(labelText: 'Turso Database URL'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: tokenCtrl,
              decoration: const InputDecoration(labelText: 'Turso Auth Token'),
              maxLines: 3,
            ),
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
    text: controller.settings.r2SecretAccessKey ??
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
                decoration: const InputDecoration(labelText: 'Secret Access Key'),
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
                bucket: bucketCtrl.text.trim().isNotEmpty ? bucketCtrl.text.trim() : null,
                endpoint: endpointCtrl.text.trim().isNotEmpty ? endpointCtrl.text.trim() : null,
                accessKeyId: keyIdCtrl.text.trim().isNotEmpty ? keyIdCtrl.text.trim() : null,
                secretAccessKey: secretCtrl.text.trim().isNotEmpty ? secretCtrl.text.trim() : null,
                enabled: bucketCtrl.text.trim().isNotEmpty && secretCtrl.text.trim().isNotEmpty,
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
      icon: SyncSpinIcon(
        isSyncing: _isSyncing,
        size: 14,
        color: Colors.black,
      ),
      label: Text(_isSyncing ? 'SYNCING…' : 'SYNC NOW (TURSO & R2)'),
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
                              ? '⚡ Bidirectional Turso & R2 sync complete!'
                              : '⚠️ Turso sync failed. Check connection.',
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
