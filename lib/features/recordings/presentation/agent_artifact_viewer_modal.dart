import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../domain/agent_artifact.dart';
import '../domain/recording.dart';
import 'recordings_controller.dart';

/// Shows the content of an agent artifact (result note or connected note)
/// in an in-app viewer with actions to copy, open externally, or create a capture.
Future<void> showAgentArtifactViewer(
  BuildContext context, {
  required RecordingsController controller,
  required Recording recording,
  required AgentArtifact artifact,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext sheetContext) => _AgentArtifactViewerModal(
      controller: controller,
      recording: recording,
      artifact: artifact,
    ),
  );
}

class _AgentArtifactViewerModal extends StatefulWidget {
  const _AgentArtifactViewerModal({
    required this.controller,
    required this.recording,
    required this.artifact,
  });

  final RecordingsController controller;
  final Recording recording;
  final AgentArtifact artifact;

  @override
  State<_AgentArtifactViewerModal> createState() =>
      __AgentArtifactViewerModalState();
}

class __AgentArtifactViewerModalState
    extends State<_AgentArtifactViewerModal> {
  String? _content;
  bool _loading = true;
  String? _error;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _loadFileContent();
  }

  Future<void> _loadFileContent() async {
    try {
      final File file = File(widget.artifact.path);
      if (!await file.exists()) {
        setState(() {
          _error = 'File not found at ${widget.artifact.path}';
          _loading = false;
        });
        return;
      }
      final String text = await file.readAsString();
      setState(() {
        _content = text;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not read artifact file: $e';
        _loading = false;
      });
    }
  }

  Future<void> _copyContent() async {
    if (_content == null) return;
    await Clipboard.setData(ClipboardData(text: _content!));
    if (!mounted) return;
    setState(() => _copied = true);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _openExternal() async {
    try {
      if (Platform.isMacOS || Platform.isLinux) {
        await Process.run('open', <String>[widget.artifact.path]);
      }
    } catch (_) {}
  }

  Future<void> _promoteToNote() async {
    if (_content == null || _content!.trim().isEmpty) return;
    await widget.controller.addTextNote(_content!);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final double maxHeight = MediaQuery.of(context).size.height * 0.85;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: Console.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: Console.borderStrong),
          left: BorderSide(color: Console.borderStrong),
          right: BorderSide(color: Console.borderStrong),
        ),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottomInset + 20),
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
            children: <Widget>[
              Icon(
                widget.artifact.kind == AgentArtifactKind.resultNote
                    ? Icons.auto_awesome
                    : Icons.description_outlined,
                color: Console.accent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.artifact.title,
                  style: TextStyle(
                    color: Console.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                color: Console.muted,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Text(
            widget.artifact.path,
            style: TextStyle(
              color: Console.dimText,
              fontSize: 11,
              fontFamily: 'JetBrainsMono',
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(color: Console.accent))
                : _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          style: TextStyle(color: Console.redSoft),
                        ),
                      )
                    : SingleChildScrollView(
                        child: SelectableText(
                          _content ?? '',
                          style: TextStyle(
                            color: Console.text,
                            fontSize: 13,
                            height: 1.5,
                            fontFamily: 'JetBrainsMono',
                          ),
                        ),
                      ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _openExternal,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open File'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Console.text,
                  side: BorderSide(color: Console.borderStrong),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _copied ? null : _copyContent,
                icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
                label: Text(_copied ? 'Copied' : 'Copy'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Console.text,
                  side: BorderSide(color: Console.borderStrong),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _promoteToNote,
                icon: const Icon(Icons.note_add, size: 16),
                label: const Text('As New Capture'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Console.accent,
                  foregroundColor: Console.ink,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
