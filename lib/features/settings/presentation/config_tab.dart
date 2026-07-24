import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/audio_config.dart';
import '../domain/provider_profile.dart';
import 'settings_controller.dart';

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
  });

  final SettingsController controller;
  final String? storagePath;
  final int recordingsCount;
  final int logCount;
  final VoidCallback onOpenModels;

  @override
  Widget build(BuildContext context) {
    final AudioConfig audio = controller.audio;
    final ProviderProfile? active = controller.activeProfile;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
        children: <Widget>[
          if (controller.error != null) ErrorBanner(message: controller.error!),
          const SectionHeader(title: 'AUDIO CAPTURE'),
          const SizedBox(height: 12),
          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const InfoRow(label: 'KODEK', value: 'AAC-LC · .m4a (stały)'),
                const Divider(color: Console.border, height: 22),
                _ChoiceRow<int>(
                  label: 'SAMPLE RATE',
                  value: audio.sampleRate,
                  options: AudioConfig.sampleRateOptions,
                  labelFor: (int value) => '${value ~/ 1000} kHz',
                  onChanged: (int value) => controller
                      .updateAudio(audio.copyWith(sampleRate: value)),
                ),
                const SizedBox(height: 10),
                _ChoiceRow<int>(
                  label: 'BITRATE',
                  value: audio.bitRate,
                  options: AudioConfig.bitRateOptions,
                  labelFor: (int value) => '${value ~/ 1000} kbps',
                  onChanged: (int value) =>
                      controller.updateAudio(audio.copyWith(bitRate: value)),
                ),
                const SizedBox(height: 10),
                _ChoiceRow<int>(
                  label: 'KANAŁY',
                  value: audio.numChannels,
                  options: const <int>[1, 2],
                  labelFor: (int value) => value == 1 ? 'Mono' : 'Stereo',
                  onChanged: (int value) =>
                      controller.updateAudio(audio.copyWith(numChannels: value)),
                ),
                const Divider(color: Console.border, height: 22),
                InfoRow(
                  label: 'ROZMIAR',
                  value: '~${_megabytesPerHour(audio).toStringAsFixed(0)} MB '
                      'na godzinę nagrania',
                ),
                const SizedBox(height: 6),
                const Text(
                  'Zmiana dotyczy kolejnych nagrań. Pliki już zapisane '
                  'pozostają bez zmian.',
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
                    label: const Text('PRZYWRÓĆ DOMYŚLNE'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const SectionHeader(title: 'TRANSCRIPTION'),
          const SizedBox(height: 12),
          ConsoleCard(
            accent: active == null ? Console.border : Console.cyan,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                InfoRow(
                  label: 'AKTYWNY PROFIL',
                  value: active?.name ?? 'Brak — transkrypcja wyłączona',
                  valueColor: active == null ? Console.amber : Console.text,
                ),
                InfoRow(
                  label: 'ENDPOINT',
                  value: active?.endpoint ?? '—',
                  monospace: true,
                ),
                InfoRow(label: 'MODEL', value: active?.model ?? '—'),
                InfoRow(label: 'JĘZYK', value: active?.language ?? 'auto'),
                InfoRow(
                  label: 'TOKEN',
                  value: active?.bearerToken == null
                      ? 'brak'
                      : '•••• ustawiony (jawny tekst na dysku)',
                  valueColor:
                      active?.bearerToken == null ? Console.mutedSoft : Console.amber,
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: onOpenModels,
                    icon: const Icon(Icons.memory_outlined, size: 17),
                    label: const Text('ZARZĄDZAJ PROFILAMI'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const SectionHeader(title: 'STORAGE'),
          const SizedBox(height: 12),
          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                InfoRow(
                  label: 'KATALOG',
                  value: storagePath ?? 'ustalanie…',
                  monospace: true,
                ),
                InfoRow(label: 'NAGRANIA', value: '$recordingsCount plików .m4a'),
                InfoRow(label: 'INDEKS', value: 'recordings.json'),
                InfoRow(label: 'USTAWIENIA', value: 'settings.json'),
                InfoRow(label: 'LOGI', value: 'logs.json · $logCount zdarzeń'),
                const SizedBox(height: 10),
                const Text(
                  'Wszystkie zapisy są atomowe: plik .tmp, potem rename. '
                  'Aplikacja nigdy nie usuwa nagrań.',
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

class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
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
          style: const TextStyle(
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
            return ChoiceChip(
              selected: active,
              onSelected: (_) => onChanged(option),
              label: Text(labelFor(option)),
              labelStyle: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: active ? Console.ink : const Color(0xFF9CB3C7),
              ),
              selectedColor: Console.cyan,
              backgroundColor: Console.surfaceRaised,
              side: BorderSide.none,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
