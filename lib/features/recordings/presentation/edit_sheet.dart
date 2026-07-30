import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/recording.dart';

/// Inline editor for an item's title and processor-output text. The app has no
/// dialogs for editing — this is a bottom sheet, like the note composer.
class EditResult {
  const EditResult({required this.title, required this.transcript});
  final String title;
  final String transcript;
}

/// Two-field editor: title (optional) and the processor-output text. Prefilled
/// from the item; returns the trimmed values on Save, null on cancel.
class EditSheet extends StatefulWidget {
  const EditSheet({super.key, required this.recording});

  final Recording recording;

  @override
  State<EditSheet> createState() => EditSheetState();
}

class EditSheetState extends State<EditSheet> {
  late final TextEditingController _title =
      TextEditingController(text: widget.recording.title ?? '');
  late final TextEditingController _text =
      TextEditingController(text: widget.recording.transcript ?? '');

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
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
