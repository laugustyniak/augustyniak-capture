import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../enrichment/domain/enrichment_context.dart';
import '../../projects/data/project_context_reader.dart';
import 'settings_controller.dart';

/// The "who I am" text handed to the enrichment model with every capture.
///
/// Stateful for the same reason `RecordingEditor` is: the field has to survive
/// the controller's notifications, and a background write must never overwrite
/// what someone is halfway through typing.
class EnrichmentContextSection extends StatefulWidget {
  const EnrichmentContextSection({super.key, required this.controller});

  final SettingsController controller;

  @override
  State<EnrichmentContextSection> createState() =>
      _EnrichmentContextSectionState();
}

class _EnrichmentContextSectionState extends State<EnrichmentContextSection> {
  late final TextEditingController _field = TextEditingController(
    text: _stored,
  );
  final FocusNode _focus = FocusNode();

  /// The last value taken *from* settings. Dirty is a difference from this, not
  /// from the settings object — which is what lets a save land without the
  /// field flickering, and stops a reload from clobbering an in-progress edit.
  late String _synced = _stored;

  String get _stored => widget.controller.enrichmentInstructions ?? '';
  bool get _dirty => _field.text.trim() != _synced.trim();

  @override
  void initState() {
    super.initState();
    // Commit on blur, like every other field in this app. There is no SAVE for
    // text elsewhere either; the amber UNSAVED marker is the safety net that
    // keeps "saved when you looked away" from being indistinguishable from
    // "lost your edit".
    _focus.addListener(() {
      if (!_focus.hasFocus && _dirty) _commit();
    });
  }

  @override
  void didUpdateWidget(EnrichmentContextSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Adopt an external change only while the field is clean.
    if (_stored != _synced && !_dirty) {
      _synced = _stored;
      _field.text = _synced;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _field.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    final String value = _field.text.trim();
    setState(() => _synced = value);
    await widget.controller.setEnrichmentInstructions(value);
  }

  void _revert() {
    setState(() {
      _synced = _stored;
      _field.text = _synced;
    });
  }

  @override
  Widget build(BuildContext context) {
    final int length = _field.text.trim().length;
    final bool overLimit = length > EnrichmentContext.maxProfileChars;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SectionHeader(title: 'ENRICHMENT CONTEXT'),
        const SizedBox(height: 12),
        ConsoleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Who you are and what you collect. Sent with every capture so '
                'titles, categories and tags match how you actually file '
                'things. Leave it empty and nothing is sent.',
                style: TextStyle(
                  color: Console.mutedSoft,
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 10),
              ConsoleField(
                controller: _field,
                focusNode: _focus,
                minLines: 5,
                maxLines: 12,
                fontSize: 12,
                hintText:
                    'e.g. I build offline-first Flutter apps and run a small '
                    'consultancy. I capture product ideas, meeting notes and '
                    'specs for coding agents. File anything with a repo name '
                    'in it as an agent task.',
                // Rebuilds the counter and the UNSAVED marker as the user
                // types; the value itself is not written until blur.
                onChanged: (String _) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Text(
                    '$length / ${EnrichmentContext.maxProfileChars}',
                    style: ConsoleText.micro.copyWith(
                      color: overLimit ? Console.amber : Console.dim,
                    ),
                  ),
                  if (overLimit) ...<Widget>[
                    const SizedBox(width: 8),
                    Text(
                      'TRUNCATED WHEN SENT',
                      style: ConsoleText.micro.copyWith(color: Console.amber),
                    ),
                  ],
                  const Spacer(),
                  if (_dirty) ...<Widget>[
                    Text(
                      'UNSAVED',
                      style: ConsoleText.micro.copyWith(color: Console.amber),
                    ),
                    const SizedBox(width: 10),
                    TextButton(onPressed: _revert, child: const Text('REVERT')),
                    TextButton(onPressed: _commit, child: const Text('SAVE')),
                  ],
                ],
              ),
              const Divider(color: Console.border, height: 26),
              const InfoRow(
                label: 'PROJECT CONTEXT',
                value: 'read from the repository',
              ),
              const SizedBox(height: 6),
              Text(
                'A capture filed under a project also carries that project\'s '
                'own description. The first of '
                '${ProjectContextReader.defaultCandidates.take(3).join(", ")} '
                'found in its repository is used, so the repo stays the source '
                'of truth and the context updates itself. The Logs tab names '
                'the file that was used.',
                style: const TextStyle(
                  color: Console.mutedSoft,
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
