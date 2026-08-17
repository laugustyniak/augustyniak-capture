import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../transcription/data/whisper_model_store.dart';
import '../../transcription/domain/whisper_model.dart';
import 'settings_controller.dart';

/// The on-device models: what can be installed, what is, and which one is
/// transcribing.
///
/// Stateful because a download is in flight across rebuilds and belongs to the
/// screen that started it — the same reason `VaultSection` holds its sweep.
class LocalModelsSection extends StatefulWidget {
  LocalModelsSection({
    super.key,
    required this.controller,
    required this.store,
  });

  final SettingsController controller;

  /// The real store in production; a subclass overriding the IO in tests, the
  /// convention `_FakeSettingsRepository` already follows.
  final WhisperModelStore store;

  @override
  State<LocalModelsSection> createState() => _LocalModelsSectionState();
}

class _LocalModelsSectionState extends State<LocalModelsSection> {
  /// Installed models by id. Null until the first scan, which is what lets the
  /// section say "checking" rather than "nothing installed" — a positive claim
  /// about the user's disk that must not be made before it has been looked at.
  Map<String, InstalledModel>? _installed;

  final Map<String, ModelDownloadProgress> _downloading =
      <String, ModelDownloadProgress>{};
  final Map<String, Completer<void>> _cancels = <String, Completer<void>>{};
  String? _failure;

  @override
  void initState() {
    super.initState();
    // From initState rather than build: it touches the filesystem, and a scan
    // per rebuild would run on every keystroke elsewhere in the tab.
    unawaited(_rescan());
  }

  Future<void> _rescan() async {
    try {
      final List<InstalledModel> found = await widget.store.installed();
      if (!mounted) return;
      setState(() {
        _installed = <String, InstalledModel>{
          for (final InstalledModel model in found) model.id: model,
        };
      });
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        _installed = const <String, InstalledModel>{};
        _failure = 'Could not read the installed models: $exception';
      });
    }
  }

  Future<void> _download(WhisperModel model) async {
    if (_downloading.containsKey(model.id)) return;
    final Completer<void> cancel = Completer<void>();
    setState(() {
      _failure = null;
      _cancels[model.id] = cancel;
      _downloading[model.id] = const ModelDownloadProgress(
        received: 0,
        total: null,
      );
    });

    try {
      await widget.store.download(
        model,
        cancelledBy: cancel.future,
        onProgress: (ModelDownloadProgress progress) {
          if (!mounted) return;
          setState(() => _downloading[model.id] = progress);
        },
      );
      await _rescan();
    } on ModelDownloadCancelled {
      // Not a failure: the user asked. Saying so in red would make a deliberate
      // act look like something went wrong.
    } catch (exception) {
      if (!mounted) return;
      setState(() => _failure = '$exception');
    } finally {
      if (mounted) {
        setState(() {
          _downloading.remove(model.id);
          _cancels.remove(model.id);
        });
      }
    }
  }

  Future<void> _delete(WhisperModel model) async {
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Delete ${model.label}?',
      message:
          'The model file is removed from this device. Captures already '
          'transcribed keep their text; downloading it again is the only cost.',
      confirmLabel: 'DELETE',
    );
    if (!confirmed) return;
    try {
      await widget.store.delete(model.id);
    } catch (exception) {
      if (mounted) setState(() => _failure = '$exception');
    }
    await _rescan();
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, InstalledModel>? installed = _installed;
    final String? activeId = widget.controller.activeLocalModelId;
    final bool engineReady = widget.controller.localEngineAvailable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHeader(
          title: ProfileKindLabels.onDeviceModels,
          trailing: '${WhisperModelCatalog.all.length} AVAILABLE',
        ),
        const SizedBox(height: 12),
        // **Said once here, not once per capture.** A build with no native
        // engine can still download and manage models; what it cannot do is
        // run one, and learning that from a failed capture an hour later is the
        // shape this app keeps designing against.
        if (!engineReady)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ErrorBanner(
              message:
                  widget.controller.localEngineIssue ??
                  'On-device transcription is not available in this build.',
            ),
          ),
        if (_failure != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ErrorBanner(message: _failure!),
          ),
        for (final WhisperModel model in WhisperModelCatalog.all)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ModelRow(
              model: model,
              installed: installed?[model.id],
              scanning: installed == null,
              progress: _downloading[model.id],
              isActive: activeId == model.id,
              engineReady: engineReady,
              onDownload: () => _download(model),
              onCancel: () {
                final Completer<void>? cancel = _cancels[model.id];
                if (cancel != null && !cancel.isCompleted) cancel.complete();
              },
              onDelete: () => _delete(model),
              onUse: () => widget.controller.useLocalModel(
                model.id,
                label: model.label,
              ),
            ),
          ),
      ],
    );
  }
}

/// Where the section header's words live, so the tab and the profile kind
/// cannot drift apart.
class ProfileKindLabels {
  const ProfileKindLabels._();

  static const String onDeviceModels = 'ON-DEVICE MODELS';
}

class _ModelRow extends StatelessWidget {
  _ModelRow({
    required this.model,
    required this.installed,
    required this.scanning,
    required this.progress,
    required this.isActive,
    required this.engineReady,
    required this.onDownload,
    required this.onCancel,
    required this.onDelete,
    required this.onUse,
  });

  final WhisperModel model;
  final InstalledModel? installed;
  final bool scanning;
  final ModelDownloadProgress? progress;
  final bool isActive;
  final bool engineReady;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
  final VoidCallback onUse;

  bool get _isInstalled => installed != null;

  @override
  Widget build(BuildContext context) {
    final ModelDownloadProgress? inFlight = progress;

    return ConsoleCard(
      accent: isActive ? Console.accent : Console.border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(model.label, style: ConsoleText.cardTitle),
              ),
              if (isActive)
                StatusPill(label: 'ACTIVE', color: Console.accent)
              else if (_isInstalled)
                StatusPill(
                  label: 'INSTALLED',
                  color: Console.green,
                  outlined: true,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(model.note, style: ConsoleText.micro),
          const SizedBox(height: 8),
          Text(_statusLine(), style: ConsoleText.micro),
          if (inFlight != null) ...<Widget>[
            const SizedBox(height: 8),
            // Indeterminate when the server promised no length: a bar drawn
            // against a fabricated denominator is worse than one that admits
            // it does not know.
            LinearProgressIndicator(
              value: inFlight.fraction,
              color: Console.accent,
              backgroundColor: Console.border,
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (inFlight != null)
                ConsoleChip(
                  label: 'CANCEL',
                  selected: false,
                  onSelected: onCancel,
                )
              else if (!_isInstalled)
                ConsoleChip(
                  label: 'DOWNLOAD',
                  selected: false,
                  onSelected: scanning ? () {} : onDownload,
                )
              else ...<Widget>[
                if (!isActive)
                  ConsoleChip(
                    label: 'USE',
                    selected: false,
                    // Downloadable and deletable without an engine; only
                    // *using* one needs the native side, and a control that
                    // can only fail is worse than one that is not there.
                    onSelected: engineReady ? onUse : () {},
                  ),
                ConsoleChip(
                  label: 'DELETE',
                  selected: false,
                  onSelected: onDelete,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _statusLine() {
    final ModelDownloadProgress? inFlight = progress;
    if (inFlight != null) {
      final double? fraction = inFlight.fraction;
      // `formatBytes` answers null below one byte, which is the honest reading
      // for a legacy row with no recorded size — here it just means the first
      // chunk has not landed.
      final String size = formatBytes(inFlight.received) ?? '0 B';
      return fraction == null
          ? 'Downloading · $size so far'
          : 'Downloading · ${(fraction * 100).round()}% of '
                '${formatBytes(inFlight.total!) ?? '0 B'}';
    }
    if (scanning) return 'Checking…';

    final InstalledModel? here = installed;
    if (here == null) {
      // Approximate, and labelled as such: it sizes the decision before the
      // download starts and nothing verifies against it.
      return 'Not installed · about ${formatBytes(model.approximateBytes)}';
    }
    // "Checked and correct" and "nothing to check against" are different
    // claims, and only the first is worth making silently.
    final String size = formatBytes(here.bytes) ?? '0 B';
    return here.verified
        ? 'Installed · $size · checksum verified'
        : 'Installed · $size · no published checksum to verify against';
  }
}
