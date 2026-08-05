import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../projects/data/directory_picker.dart';
import '../../recordings/domain/note_vault.dart';
import 'settings_controller.dart';

/// The second place every capture is written to, as markdown with front matter.
///
/// Stateful for the same reason `EnrichmentContextSection` is: the two path
/// fields have to survive the controller's notifications, and a background save
/// must never overwrite what somebody is halfway through typing.
class VaultSection extends StatefulWidget {
  VaultSection({
    super.key,
    required this.controller,
    this.picker = const FilePickerDirectoryPicker(),
    this.onMirrorAll,
  });

  final SettingsController controller;

  /// Same seam, same reason as the project editor's: the widget suite injects a
  /// fake and never reaches `file_picker`. Desktop-only by `isAvailable`, so on
  /// mobile the typed field simply stands alone.
  final DirectoryPicker picker;

  /// Copies the whole existing queue across. Null where there is no recordings
  /// controller to ask — every current Config test, and any host that renders
  /// this tab on its own.
  final Future<VaultMirrorSummary> Function()? onMirrorAll;

  @override
  State<VaultSection> createState() => _VaultSectionState();
}

class _VaultSectionState extends State<VaultSection> {
  late final TextEditingController _path = TextEditingController(
    text: _storedPath,
  );
  late final TextEditingController _folder = TextEditingController(
    text: _storedFolder,
  );
  final FocusNode _pathFocus = FocusNode();
  final FocusNode _folderFocus = FocusNode();

  /// The last values taken *from* settings — dirty is a difference from these,
  /// not from the settings object, so a save can land without the field
  /// flickering and a reload cannot clobber an edit in progress.
  late String _syncedPath = _storedPath;
  late String _syncedFolder = _storedFolder;

  /// What the last sweep did. Null until one runs; it is a report of an action,
  /// not a state of the vault, so it deliberately does not survive a rebuild of
  /// the tab.
  VaultMirrorSummary? _summary;
  bool _sweeping = false;

  /// A dialog that threw. Reported inline for the same reason the project
  /// editor reports it: a browse button that does nothing is indistinguishable
  /// from a dead one.
  String? _pickerError;

  String get _storedPath => widget.controller.vaultPath ?? '';
  String get _storedFolder => widget.controller.vaultFolder;
  bool get _pathDirty => _path.text.trim() != _syncedPath.trim();
  bool get _folderDirty => _folder.text.trim() != _syncedFolder.trim();

  @override
  void initState() {
    super.initState();
    // Commit on blur, like every other text field in this app.
    _pathFocus.addListener(() {
      if (!_pathFocus.hasFocus && _pathDirty) _commitPath();
    });
    _folderFocus.addListener(() {
      if (!_folderFocus.hasFocus && _folderDirty) _commitFolder();
    });
  }

  @override
  void didUpdateWidget(VaultSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Adopt an external change only while the field is clean.
    if (_storedPath != _syncedPath && !_pathDirty) {
      _syncedPath = _storedPath;
      _path.text = _syncedPath;
    }
    if (_storedFolder != _syncedFolder && !_folderDirty) {
      _syncedFolder = _storedFolder;
      _folder.text = _syncedFolder;
    }
  }

  @override
  void dispose() {
    _pathFocus.dispose();
    _folderFocus.dispose();
    _path.dispose();
    _folder.dispose();
    super.dispose();
  }

  Future<void> _commitPath() async {
    final String value = _path.text.trim();
    setState(() => _syncedPath = value);
    await widget.controller.setVaultPath(value);
  }

  Future<void> _commitFolder() async {
    final String value = _folder.text.trim();
    setState(() => _syncedFolder = value);
    await widget.controller.setVaultFolder(value);
  }

  Future<void> _browse() async {
    setState(() => _pickerError = null);
    try {
      final String? chosen = await widget.picker.pick(
        initialDirectory: _syncedPath.isEmpty ? null : _syncedPath,
      );
      // A cancel leaves the field exactly as it was — the typed value stays
      // authoritative, here as in the project editor.
      if (chosen == null || !mounted) return;
      _path.text = chosen;
      await _commitPath();
    } catch (exception) {
      if (!mounted) return;
      setState(() => _pickerError = exception.toString());
    }
  }

  Future<void> _mirrorAll() async {
    final Future<VaultMirrorSummary> Function()? sweep = widget.onMirrorAll;
    if (sweep == null || _sweeping) return;
    setState(() => _sweeping = true);
    try {
      final VaultMirrorSummary summary = await sweep();
      if (!mounted) return;
      setState(() => _summary = summary);
    } finally {
      if (mounted) setState(() => _sweeping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool configured = widget.controller.mirrorsToVault;
    final bool copies = widget.controller.vaultCopySources;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHeader(title: 'NOTE VAULT'),
        const SizedBox(height: 12),
        ConsoleCard(
          accent: configured ? Console.accent : Console.border,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'A second copy of every capture, written as a markdown '
                      'file with its title, tags and category in YAML front '
                      'matter — for Obsidian, a synced folder, or a notes '
                      'repository. The queue stays the original; this is a '
                      'copy, and deleting one here never touches the other.',
                      style: TextStyle(
                        color: Console.mutedSoft,
                        fontSize: 10,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    configured ? 'MIRRORING' : 'OFF',
                    style: ConsoleText.micro.copyWith(
                      color: configured ? Console.accent : Console.dimText,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _FieldLabel(text: 'VAULT DIRECTORY'),
              const SizedBox(height: 6),
              ConsoleField(
                controller: _path,
                focusNode: _pathFocus,
                monospace: true,
                fontSize: 12,
                textInputAction: TextInputAction.done,
                onSubmitted: (String _) => _commitPath(),
                onChanged: (String _) => setState(() {}),
                hintText: '/Users/you/Obsidian/Vault',
                suffixIcon: widget.picker.isAvailable
                    ? IconButton(
                        onPressed: _browse,
                        icon: const Icon(Icons.folder_open, size: 18),
                        tooltip: 'Browse',
                        color: Console.muted,
                      )
                    : null,
              ),
              const SizedBox(height: 6),
              Text(
                'Leave it empty to mirror nothing. Nothing is written until a '
                'capture finishes processing.',
                style: TextStyle(
                  color: Console.mutedSoft,
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              _FieldLabel(text: 'SUBFOLDER'),
              const SizedBox(height: 6),
              ConsoleField(
                controller: _folder,
                focusNode: _folderFocus,
                monospace: true,
                fontSize: 12,
                textInputAction: TextInputAction.done,
                onSubmitted: (String _) => _commitFolder(),
                onChanged: (String _) => setState(() {}),
                hintText: VaultDefaults.folder,
              ),
              if (_pathDirty || _folderDirty) ...<Widget>[
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Text(
                      'UNSAVED',
                      style: ConsoleText.micro.copyWith(color: Console.amber),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _path.text = _syncedPath;
                          _folder.text = _syncedFolder;
                        });
                      },
                      child: const Text('REVERT'),
                    ),
                    TextButton(
                      onPressed: () async {
                        if (_pathDirty) await _commitPath();
                        if (_folderDirty) await _commitFolder();
                      },
                      child: const Text('SAVE'),
                    ),
                  ],
                ),
              ],
              if (_pickerError != null) ...<Widget>[
                const SizedBox(height: 10),
                ErrorBanner(message: _pickerError!),
              ],
              Divider(color: Console.border, height: 26),
              _FieldLabel(text: 'SOURCE FILES'),
              const SizedBox(height: 7),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  ConsoleChip(
                    label: 'COPY INTO VAULT',
                    selected: copies,
                    onSelected: () =>
                        widget.controller.setVaultCopySources(true),
                  ),
                  ConsoleChip(
                    label: 'NOTE TEXT ONLY',
                    selected: !copies,
                    onSelected: () =>
                        widget.controller.setVaultCopySources(false),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                copies
                    ? 'Recordings, images and video are copied next to their '
                          'note and embedded, so they play from the vault. The '
                          'vault grows by the full size of every capture.'
                    : 'Only the text is copied. The note names its source file '
                          'but the media stays where the app keeps it.',
                style: TextStyle(
                  color: Console.mutedSoft,
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              Divider(color: Console.border, height: 26),
              InfoRow(
                label: 'NOTES',
                value: configured ? _notesPath() : 'not mirroring',
                monospace: true,
                valueColor: configured ? Console.text : Console.dimText,
              ),
              InfoRow(
                label: 'ATTACHMENTS',
                value: configured && copies
                    ? '${_notesPath()}/${VaultDefaults.attachments}'
                    : '—',
                monospace: true,
                valueColor: configured && copies
                    ? Console.text
                    : Console.dimText,
              ),
              const SizedBox(height: 10),
              Text(
                'A note is found again by its capture id, so a title arriving '
                'later updates the file instead of adding a second one. Once '
                'you edit a note in the vault the app stops rewriting it — the '
                'edit wins, and the Logs tab says which note was left alone.',
                style: TextStyle(
                  color: Console.mutedSoft,
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  if (_summary != null)
                    Expanded(
                      child: Text(
                        _summaryLine(_summary!),
                        style: ConsoleText.micro.copyWith(
                          color: _summary!.foreign > 0 || _summary!.failed > 0
                              ? Console.amber
                              : Console.muted,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  if (_sweeping)
                    Text(
                      'MIRRORING…',
                      style: ConsoleText.micro.copyWith(color: Console.accent),
                    )
                  else
                    TextButton.icon(
                      // Disabled rather than hidden: unlike the card's route
                      // button this one sits in a settings panel the user came
                      // to on purpose, and its greyed state is what explains
                      // that the directory above has to be set first.
                      onPressed: configured && widget.onMirrorAll != null
                          ? _mirrorAll
                          : null,
                      icon: const Icon(Icons.sync, size: 17),
                      label: const Text('MIRROR EVERYTHING'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Where notes actually land, rendered rather than described — a subfolder
  /// that silently fell back to the default is otherwise invisible.
  String _notesPath() {
    final String folder = _syncedFolder.trim().isEmpty
        ? VaultDefaults.folder
        : _syncedFolder.trim();
    return '${_syncedPath.trim()}/$folder';
  }

  String _summaryLine(VaultMirrorSummary summary) {
    if (summary.total == 0) return 'Nothing to mirror yet.';
    final List<String> parts = <String>[
      if (summary.created > 0) '${summary.created} new',
      if (summary.updated > 0) '${summary.updated} updated',
      if (summary.unchanged > 0) '${summary.unchanged} unchanged',
      if (summary.foreign > 0) '${summary.foreign} edited in the vault',
      if (summary.failed > 0) '${summary.failed} failed',
    ];
    return parts.join(' · ');
  }
}

/// The same 9 px all-caps label the choice rows in `ConfigTab` use. Declared
/// here rather than shared because that one is private to the tab, and a
/// non-const constructor is required either way — it paints the palette.
class _FieldLabel extends StatelessWidget {
  _FieldLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      color: Console.muted,
      fontSize: 9,
      fontWeight: FontWeight.w800,
      letterSpacing: .6,
    ),
  );
}
