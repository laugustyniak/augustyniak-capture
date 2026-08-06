import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../projects/domain/project.dart';
import '../../recordings/domain/note_vault.dart';
import '../../shortcuts/domain/shortcut_action.dart';
import '../../shortcuts/presentation/shortcuts_section.dart';
import '../domain/app_theme_mode.dart';
import '../domain/audio_config.dart';
import '../domain/provider_profile.dart';
import '../domain/token_cipher.dart';
import 'enrichment_context_section.dart';
import 'settings_controller.dart';
import 'vault_section.dart';

/// Runtime settings: capture parameters plus a read-only view of where data
/// lives and which provider is active. Provider editing lives in the Models tab.
class ConfigTab extends StatelessWidget {
  const ConfigTab({
    super.key,
    required this.controller,
    required this.storagePath,
    required this.recordingsCount,
    required this.logCount,
    required this.onOpenModels,
    this.projects = const <Project>[],
    this.showShortcuts = false,
    this.rejectedShortcuts = const <ShortcutAction>{},
    this.runWithHotkeysSuspended = _runDirectly,
    this.onMirrorAll,
  });

  /// Default for callers with no coordinator (mobile, tests): just run it.
  static Future<void> _runDirectly(Future<void> Function() action) => action();

  final SettingsController controller;
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
                InfoRow(label: 'SETTINGS', value: 'settings.json'),
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
    return '•••• unreadable — keyring unavailable';
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
