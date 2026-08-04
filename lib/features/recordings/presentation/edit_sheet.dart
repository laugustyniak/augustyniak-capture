import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_category.dart';
import '../domain/recording.dart';
import '../domain/recording_revision.dart';

/// Inline editor for an item's title and processor-output text. The app has no
/// dialogs for editing — this is a bottom sheet, like the note composer.
class EditResult {
  const EditResult({
    required this.title,
    required this.transcript,
    required this.category,
    required this.tags,
  });

  final String title;
  final String transcript;

  /// The corrected category, or null for "unclassified". A wrong category is
  /// worse than none, because an export will read this field.
  final CaptureCategory? category;

  /// User-entered tags, normalized by the controller before persistence.
  final List<String> tags;
}

/// Two-field editor: title (optional) and the processor-output text. Prefilled
/// from the item; returns the trimmed values on Save, null on cancel.
class EditSheet extends StatefulWidget {
  const EditSheet({
    super.key,
    required this.recording,
    this.revisions = const <RecordingRevision>[],
  });

  final Recording recording;

  /// What has been overwritten on this item, newest first. Empty on a capture
  /// that was processed once and never re-run, which is the common case — the
  /// section then draws nothing at all rather than an empty panel.
  final List<RecordingRevision> revisions;

  @override
  State<EditSheet> createState() => EditSheetState();
}

class EditSheetState extends State<EditSheet> {
  late final TextEditingController _title = TextEditingController(
    text: widget.recording.title ?? '',
  );
  late final TextEditingController _text = TextEditingController(
    text: widget.recording.transcript ?? '',
  );
  late final TextEditingController _tags = TextEditingController(
    text: widget.recording.tags.join(', '),
  );
  late CaptureCategory? _category = widget.recording.category;

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    _tags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 18,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionHeader(title: 'EDIT'),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            textInputAction: TextInputAction.next,
            style: const TextStyle(color: Console.text, fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Title (optional)',
              hintText: 'e.g. Client meeting',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<CaptureCategory?>(
            initialValue: _category,
            dropdownColor: Console.surfaceRaised,
            style: const TextStyle(color: Console.text, fontSize: 14),
            decoration: const InputDecoration(labelText: 'Category'),
            items: <DropdownMenuItem<CaptureCategory?>>[
              const DropdownMenuItem<CaptureCategory?>(
                value: null,
                child: Text('—'),
              ),
              for (final CaptureCategory value in CaptureCategory.values)
                DropdownMenuItem<CaptureCategory?>(
                  value: value,
                  child: Text(value.label),
                ),
            ],
            onChanged: (CaptureCategory? value) =>
                setState(() => _category = value),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            maxLines: 6,
            minLines: 3,
            style: const TextStyle(color: Console.text, fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Text',
              hintText: 'Transcript / OCR text / note',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            textInputAction: TextInputAction.done,
            style: const TextStyle(color: Console.text, fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Tags',
              hintText: 'project:acme, client, published',
              helperText: 'Separate tags with commas',
            ),
          ),
          if (widget.revisions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            _HistorySection(revisions: widget.revisions),
          ],
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('CANCEL'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(
                  EditResult(
                    title: _title.text,
                    transcript: _text.text,
                    category: _category,
                    tags: _tags.text.split(','),
                  ),
                ),
                child: const Text('SAVE'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Collapsed-by-default list of everything that has been overwritten on this
/// item, newest first.
///
/// Collapsed because the sheet's job is editing and this is reference material:
/// an item re-run a few times would otherwise push SAVE off the screen. It also
/// keeps the app's no-dialog rule — the history is inline, in the place where
/// the question "what did this say before?" actually comes up.
class _HistorySection extends StatefulWidget {
  const _HistorySection({required this.revisions});

  final List<RecordingRevision> revisions;

  @override
  State<_HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends State<_HistorySection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: SectionHeader(
                    title: 'HISTORY',
                    trailing: '${widget.revisions.length} change'
                        '${widget.revisions.length == 1 ? '' : 's'}',
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: Console.muted,
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...<Widget>[
          const SizedBox(height: 6),
          // Bounded and independently scrollable: the sheet itself does not
          // scroll, so an item with a long history must not be able to push the
          // SAVE row out of reach.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: widget.revisions.length,
              separatorBuilder: (BuildContext _, int _) =>
                  const SizedBox(height: 8),
              itemBuilder: (BuildContext _, int index) =>
                  _RevisionTile(revision: widget.revisions[index]),
            ),
          ),
        ],
      ],
    );
  }
}

class _RevisionTile extends StatelessWidget {
  const _RevisionTile({required this.revision});

  final RecordingRevision revision;

  /// Long enough to recognise a transcript, short enough that three entries
  /// still fit. The full value always goes to the clipboard button regardless.
  static const int _previewLength = 220;

  static String _preview(String? value) {
    if (value == null || value.isEmpty) return '—';
    final String collapsed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= _previewLength) return collapsed;
    return '${collapsed.substring(0, _previewLength)}…';
  }

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusPill(
                label: revision.source.label,
                color: revision.source == RevisionSource.user
                    ? Console.muted
                    : Console.cyan,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${revision.field} · ${formatDateTime(revision.at)}',
                  style: ConsoleText.micro,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // The point of the whole feature: the overwritten value is the
              // one thing no longer reachable anywhere else, so it is what the
              // clipboard button hands back — in full, never the preview.
              if ((revision.from ?? '').isNotEmpty)
                CopyButton(
                  text: revision.from!,
                  tooltip: 'Copy the previous value',
                  semanticLabel: 'Copy the previous ${revision.field}',
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _preview(revision.from),
            style: ConsoleText.micro.copyWith(
              color: Console.textSoft,
              decoration: TextDecoration.lineThrough,
              decorationColor: Console.muted,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('→ ', style: TextStyle(color: Console.muted)),
              Expanded(
                child: Text(
                  _preview(revision.to),
                  style: ConsoleText.micro.copyWith(color: Console.text),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
