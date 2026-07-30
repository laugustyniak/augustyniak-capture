import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/provider_profile.dart';
import 'settings_controller.dart';

/// Manages provider profiles for both pipeline stages.
///
/// One list, two sections: transcription turns audio into text, enrichment
/// turns that text into a title, a category, a summary and tags. Exactly one
/// profile of each kind is active, and the page shell pushes both services into
/// the recordings controller. They are independent — running transcription with
/// no enrichment profile (or the reverse) is a supported configuration.
class ModelsTab extends StatelessWidget {
  const ModelsTab({super.key, required this.controller});

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    final List<ProviderProfile> profiles = controller.profiles;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
        children: <Widget>[
          ConsoleHeader(
            title: 'Models',
            trailing:
                '${profiles.length} ${profiles.length == 1 ? 'profile' : 'profiles'}',
          ),
          const SizedBox(height: 18),
          if (controller.error != null) ErrorBanner(message: controller.error!),
          ..._section(context, ProfileKind.transcription),
          const SizedBox(height: 22),
          ..._section(context, ProfileKind.enrichment),
          const SizedBox(height: 14),
          const ConsoleCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.lock_outline, size: 16, color: Console.amber),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Tokens are stored as plaintext in the app documents '
                    'directory (settings.json). Encryption is planned for a '
                    'later phase.',
                    style: TextStyle(
                      color: Console.mutedSoft,
                      fontSize: 11,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One kind's block: its active-profile card, its profiles, its add button.
  /// Everything below the kind switch is shared — the two stages differ only in
  /// which controller setter a tap reaches and which copy the empty state shows.
  List<Widget> _section(BuildContext context, ProfileKind kind) {
    final List<ProviderProfile> profiles = controller.profilesOfKind(kind);
    final bool isTranscription = kind == ProfileKind.transcription;
    final String? activeId = isTranscription
        ? controller.settings.activeProfileId
        : controller.settings.activeEnrichmentProfileId;

    return <Widget>[
      _ActiveProfileCard(
        profile: isTranscription
            ? controller.activeProfile
            : controller.activeEnrichmentProfile,
        kind: kind,
      ),
      const SizedBox(height: 18),
      SectionHeader(title: kind.label, trailing: '${profiles.length} ITEMS'),
      const SizedBox(height: 12),
      if (profiles.isEmpty)
        EmptyPanel(
          icon: isTranscription ? Icons.memory_outlined : Icons.auto_awesome,
          title: isTranscription
              ? 'No transcription profiles.'
              : 'No enrichment profiles.',
          blurb: isTranscription
              ? 'Add a profile to enable transcription. Recording works '
                  'without one — audio is always saved locally.'
              : 'Add a profile to have finished items named and categorised. '
                  'Without one they are captured and processed as usual, just '
                  'left untitled.',
        )
      else
        ...profiles.map(
          (ProviderProfile profile) => Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: _ProfileCard(
              profile: profile,
              isActive: profile.id == activeId,
              onActivate: () => isTranscription
                  ? controller.setActiveProfile(profile.id)
                  : controller.setActiveEnrichmentProfile(profile.id),
              onEdit: () => _openEditor(context, kind, existing: profile),
              onDelete: () => _confirmDelete(context, profile),
            ),
          ),
        ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () => _openEditor(context, kind),
        style: FilledButton.styleFrom(
          backgroundColor: Console.cyan,
          foregroundColor: Console.ink,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        icon: const Icon(Icons.add),
        label: Text(
          isTranscription ? 'ADD TRANSCRIPTION PROFILE' : 'ADD ENRICHMENT PROFILE',
          style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: .5),
        ),
      ),
    ];
  }

  Future<void> _openEditor(
    BuildContext context,
    ProfileKind kind, {
    ProviderProfile? existing,
  }) async {
    final _ProfileDraft? draft = await showModalBottomSheet<_ProfileDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Console.surfaceDeep,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (BuildContext sheetContext) =>
          _ProfileEditorSheet(kind: kind, existing: existing),
    );
    if (draft == null) return;

    if (existing == null) {
      await controller.addProfile(
        name: draft.name,
        endpoint: draft.endpoint,
        kind: kind,
        model: draft.model,
        language: draft.language,
        bearerToken: draft.bearerToken,
      );
    } else {
      await controller.updateProfile(
        existing.copyWith(
          name: draft.name,
          endpoint: draft.endpoint,
          model: draft.model,
          language: draft.language,
          bearerToken: draft.bearerToken,
          clearModel: draft.model == null,
          clearLanguage: draft.language == null,
          clearBearerToken: draft.bearerToken == null,
        ),
      );
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ProviderProfile profile,
  ) async {
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Delete profile?',
      message: '"${profile.name}" will be removed. Recordings and transcripts '
          'stay untouched.',
      confirmLabel: 'DELETE',
    );
    if (confirmed) {
      await controller.deleteProfile(profile.id);
    }
  }
}

class _ActiveProfileCard extends StatelessWidget {
  const _ActiveProfileCard({required this.profile, required this.kind});

  final ProviderProfile? profile;
  final ProfileKind kind;

  @override
  Widget build(BuildContext context) {
    final ProviderProfile? item = profile;
    return ConsoleCard(
      accent: item == null ? Console.border : Console.cyan,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ConsoleIconTile(
                icon: item == null ? Icons.cloud_off : Icons.memory,
                color: item == null ? Console.muted : Console.cyan,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item?.name ??
                          (kind == ProfileKind.transcription
                              ? 'Transcription disabled'
                              : 'Enrichment disabled'),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item?.host ?? 'No active profile',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Console.mutedSoft,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: <Widget>[
              StatusPill(
                label: item == null ? 'NOT CONFIGURED' : 'ACTIVE PROVIDER',
                color: item == null ? Console.amber : Console.cyan,
              ),
              if (item?.model != null)
                StatusPill(label: item!.model!.toUpperCase(), color: Console.green),
              // Only transcription sends a language hint; the enrichment
              // prompt asks the model to answer in the language of the input.
              if (kind == ProfileKind.transcription && item?.language != null)
                StatusPill(
                  label: 'LANG ${item!.language!.toUpperCase()}',
                  color: Console.green,
                ),
              if (item != null && item.bearerToken != null)
                const StatusPill(label: 'TOKEN SET', color: Console.green),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.isActive,
    required this.onActivate,
    required this.onEdit,
    required this.onDelete,
  });

  final ProviderProfile profile;
  final bool isActive;
  final VoidCallback onActivate;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      accent: isActive ? Console.cyan : Console.border,
      child: Row(
        children: <Widget>[
          Semantics(
            button: true,
            selected: isActive,
            label: 'Set profile as active',
            child: InkResponse(
              onTap: onActivate,
              radius: 24,
              child: Icon(
                isActive
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: isActive ? Console.cyan : Console.muted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  profile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  profile.hasEndpoint ? profile.endpoint : 'No endpoint',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: profile.hasEndpoint ? Console.mutedSoft : Console.amber,
                    fontSize: 10,
                  ),
                ),
                if (profile.model != null) ...<Widget>[
                  const SizedBox(height: 6),
                  StatusPill(
                    label: profile.model!.toUpperCase(),
                    color: Console.muted,
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 19),
            color: Console.muted,
            tooltip: 'Edit',
          ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 19),
            color: Console.redSoft,
            tooltip: 'Delete',
          ),
        ],
      ),
    );
  }
}

/// Values returned by the editor sheet. Null fields mean "clear this field".
class _ProfileDraft {
  const _ProfileDraft({
    required this.name,
    required this.endpoint,
    this.model,
    this.language,
    this.bearerToken,
  });

  final String name;
  final String endpoint;
  final String? model;
  final String? language;
  final String? bearerToken;
}

class _ProfileEditorSheet extends StatefulWidget {
  const _ProfileEditorSheet({required this.kind, this.existing});

  final ProfileKind kind;
  final ProviderProfile? existing;

  @override
  State<_ProfileEditorSheet> createState() => _ProfileEditorSheetState();
}

class _ProfileEditorSheetState extends State<_ProfileEditorSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _endpoint;
  late final TextEditingController _model;
  late final TextEditingController _language;
  late final TextEditingController _token;
  bool _obscureToken = true;

  @override
  void initState() {
    super.initState();
    final ProviderProfile? existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _endpoint = TextEditingController(text: existing?.endpoint ?? '');
    _model = TextEditingController(text: existing?.model ?? '');
    _language = TextEditingController(text: existing?.language ?? '');
    _token = TextEditingController(text: existing?.bearerToken ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _model.dispose();
    _language.dispose();
    _token.dispose();
    super.dispose();
  }

  void _applyPreset(ProviderPreset preset) {
    setState(() {
      if (_name.text.trim().isEmpty) _name.text = preset.name;
      _endpoint.text = preset.endpoint;
      _model.text = preset.model ?? '';
    });
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      _ProfileDraft(
        name: _name.text.trim(),
        endpoint: _endpoint.text.trim(),
        model: _nullIfBlank(_model.text),
        language: _nullIfBlank(_language.text),
        bearerToken: _nullIfBlank(_token.text),
      ),
    );
  }

  static String? _nullIfBlank(String value) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final bool isEdit = widget.existing != null;
    final bool isTranscription = widget.kind == ProfileKind.transcription;
    // Only the presets that speak this stage's protocol: a chat endpoint cannot
    // transcribe, and a Whisper endpoint cannot classify.
    final List<ProviderPreset> presets = ProviderPreset.all
        .where((ProviderPreset preset) => preset.kind == widget.kind)
        .toList();
    return Padding(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 18,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${isEdit ? 'EDIT' : 'NEW'} '
                    '${isTranscription ? 'TRANSCRIPTION' : 'ENRICHMENT'} PROFILE',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                  color: Console.muted,
                ),
              ),
              const SizedBox(height: 14),
              if (!isEdit) ...<Widget>[
                SizedBox(
                  height: 34,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: presets.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (BuildContext context, int index) {
                      final ProviderPreset preset = presets[index];
                      return ActionChip(
                        onPressed: () => _applyPreset(preset),
                        label: Text(preset.name),
                        labelStyle: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Console.textSoft,
                        ),
                        backgroundColor: Console.surfaceRaised,
                        side: BorderSide.none,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 14),
              ],
              _SheetField(
                controller: _name,
                label: 'Name',
                hint: isTranscription ? 'e.g. OpenAI Whisper' : 'e.g. OpenAI GPT-4o mini',
                validator: (String? value) =>
                    (value == null || value.trim().isEmpty)
                        ? 'Enter a profile name.'
                        : null,
              ),
              _SheetField(
                controller: _endpoint,
                label: 'Endpoint',
                hint: isTranscription
                    ? 'https://…/v1/audio/transcriptions'
                    : 'https://…/v1/chat/completions',
                keyboardType: TextInputType.url,
                validator: (String? value) {
                  final String text = (value ?? '').trim();
                  if (text.isEmpty) return 'Enter an endpoint URL.';
                  final Uri? uri = Uri.tryParse(text);
                  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
                    return 'The URL needs a scheme, e.g. https://host/path';
                  }
                  return null;
                },
              ),
              _SheetField(
                controller: _model,
                label: 'Model',
                hint: isTranscription
                    ? 'whisper-1 (optional)'
                    : 'gpt-4o-mini (optional)',
              ),
              // Transcription only: the enrichment prompt already asks the
              // model to answer in the language of the input text.
              if (isTranscription)
                _SheetField(
                  controller: _language,
                  label: 'Language',
                  hint: 'pl (optional, ISO-639-1)',
                ),
              _SheetField(
                controller: _token,
                label: 'Token',
                hint: 'Bearer token (optional)',
                obscure: _obscureToken,
                suffix: IconButton(
                  icon: Icon(
                    _obscureToken
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 18,
                    color: Console.muted,
                  ),
                  onPressed: () =>
                      setState(() => _obscureToken = !_obscureToken),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('CANCEL'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: Console.cyan,
                        foregroundColor: Console.ink,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        isEdit ? 'SAVE' : 'ADD',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetField extends StatelessWidget {
  const _SheetField({
    required this.controller,
    required this.label,
    required this.hint,
    this.validator,
    this.keyboardType,
    this.obscure = false,
    this.suffix,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final bool obscure;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        validator: validator,
        keyboardType: keyboardType,
        obscureText: obscure,
        style: const TextStyle(color: Console.text, fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Console.muted, fontSize: 12),
          hintText: hint,
          hintStyle: const TextStyle(color: Console.muted, fontSize: 12),
          suffixIcon: suffix,
          filled: true,
          fillColor: Console.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Console.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Console.border),
          ),
        ),
      ),
    );
  }
}
