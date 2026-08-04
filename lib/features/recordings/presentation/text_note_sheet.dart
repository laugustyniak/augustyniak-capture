import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';

/// Compose sheet for a text note. Returns the typed body via `Navigator.pop`;
/// the page persists it through `RecordingsController.addTextNote`.
///
/// The `NO NETWORK` badge and the pipeline hint under the field are not
/// decoration: a note travels the identical persist-then-process path as audio,
/// and the only thing that differs is that its processor is a passthrough that
/// never leaves the device.
class TextNoteSheet extends StatefulWidget {
  const TextNoteSheet({super.key});

  @override
  State<TextNoteSheet> createState() => _TextNoteSheetState();
}

class _TextNoteSheetState extends State<TextNoteSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _canSave = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final bool next = _controller.text.trim().isNotEmpty;
      // Rebuild on every keystroke anyway — the character counter reads the
      // live length — but only `setState` through this one call site.
      setState(() => _canSave = next);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final int characters = _controller.text.characters.length;

    return Container(
      decoration: const BoxDecoration(
        color: Console.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: Console.borderStrong),
          left: BorderSide(color: Console.borderStrong),
          right: BorderSide(color: Console.borderStrong),
        ),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottomInset + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Console.borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              const Text(
                'New text note',
                style: TextStyle(
                  fontFamily: ConsoleFont.display,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Console.text,
                ),
              ),
              const StatusPill(label: 'NO NETWORK', color: Console.cyan),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 7,
            minLines: 5,
            style: const TextStyle(
              color: Console.text,
              fontSize: 14,
              height: 1.55,
            ),
            decoration: InputDecoration(
              hintText: 'Type the note…',
              hintStyle: const TextStyle(color: Console.dim, fontSize: 14),
              filled: true,
              fillColor: Console.background,
              contentPadding: const EdgeInsets.all(14),
              border: _fieldBorder(Console.border),
              enabledBorder: _fieldBorder(Console.border),
              focusedBorder: _fieldBorder(Console.cyan.withValues(alpha: .4)),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              const Text(
                '.txt → verify → index → passthrough',
                style: ConsoleText.micro,
              ),
              Text('$characters chars', style: ConsoleText.micro),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: _SheetButton(
                  label: 'Cancel',
                  onTap: () => Navigator.pop(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _SheetButton(
                  label: 'Save note',
                  primary: true,
                  onTap: _canSave
                      ? () => Navigator.pop(context, _controller.text)
                      : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  OutlineInputBorder _fieldBorder(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: color),
  );
}

/// Sheet footer button. Primary is the cyan fill, secondary the outline —
/// there is no third weight anywhere in the design.
class _SheetButton extends StatelessWidget {
  const _SheetButton({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: primary
                ? (enabled ? Console.cyan : Console.surfaceRaised)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: primary ? null : Border.all(color: Console.borderStrong),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: ConsoleFont.display,
              fontSize: 13,
              fontWeight: primary ? FontWeight.w700 : FontWeight.w600,
              color: primary
                  ? (enabled ? Console.ink : Console.dim)
                  : Console.mutedSoft,
            ),
          ),
        ),
      ),
    );
  }
}
