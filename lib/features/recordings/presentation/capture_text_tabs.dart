import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_instruction.dart';
import '../domain/recording.dart';

/// `INSTRUCTION` / `RAW` over a capture's text (#281).
///
/// Opens on the instruction when there is one — it is what the clipboard got
/// and what the user dictated the capture for — and on the raw transcript
/// otherwise. [raw] is the host's own transcript widget, unchanged, so the
/// panel keeps its inline edit and the focus view its plain reading box.
///
/// Renders [raw] alone when there is nothing to tab between: no instruction,
/// none being written, and no way to ask for one.
class CaptureTextTabs extends StatefulWidget {
  CaptureTextTabs({
    super.key,
    required this.recording,
    required this.raw,
    required this.instructionBody,
    this.writing = false,
    this.error,
    this.onRewrite,
  });

  static const String instructionLabel = 'INSTRUCTION';
  static const String rawLabel = 'RAW';
  static const String rewriteLabel = 'REWRITE';

  final Recording recording;
  final Widget raw;

  /// The instruction text, rendered in the host's reading style.
  final Widget Function(String text) instructionBody;
  final bool writing;

  /// Why the last pass produced nothing. Shown on the instruction tab.
  final String? error;

  /// Null hides REWRITE: a typed note, or a host with no model.
  final VoidCallback? onRewrite;

  @override
  State<CaptureTextTabs> createState() => _CaptureTextTabsState();
}

class _CaptureTextTabsState extends State<CaptureTextTabs> {
  /// Null until the user picks a tab, so the default follows the instruction
  /// landing while the view is open.
  bool? _raw;

  @override
  Widget build(BuildContext context) {
    final CaptureInstruction? instruction = widget.recording.instruction;
    if (instruction == null && !widget.writing && widget.onRewrite == null) {
      return widget.raw;
    }
    final bool showRaw = _raw ?? instruction == null;
    final bool stale =
        instruction != null &&
        !instruction.matches(widget.recording.transcript);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            ConsoleChip(
              label: CaptureTextTabs.instructionLabel,
              selected: !showRaw,
              onSelected: () => setState(() => _raw = false),
            ),
            ConsoleChip(
              label: CaptureTextTabs.rawLabel,
              selected: showRaw,
              onSelected: () => setState(() => _raw = true),
            ),
            if (widget.writing)
              Text(
                'WRITING…',
                style: ConsoleText.micro.copyWith(color: Console.accent),
              )
            else if (stale)
              Text(
                'STALE — the text changed',
                style: ConsoleText.micro.copyWith(color: Console.amber),
              ),
            if (!widget.writing && widget.onRewrite != null)
              TextButton.icon(
                onPressed: widget.onRewrite,
                icon: const Icon(Icons.auto_fix_high, size: 15),
                label: const Text(CaptureTextTabs.rewriteLabel),
              ),
            if (!showRaw && instruction != null)
              CopyButton(
                text: instruction.text,
                tooltip: 'Copy instruction',
                semanticLabel: 'Copy instruction to clipboard',
                size: 28,
                iconSize: 14,
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (showRaw)
          widget.raw
        else if (instruction != null)
          widget.instructionBody(instruction.text)
        else
          Text(
            widget.writing
                ? 'Rewriting the dictation as an instruction…'
                : (widget.error ?? 'No instruction yet.'),
            style: ConsoleText.micro.copyWith(
              color: widget.error != null && !widget.writing
                  ? Console.amber
                  : Console.muted,
            ),
          ),
      ],
    );
  }
}
