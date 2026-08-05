import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/agent_handoff.dart';
import '../domain/recording.dart';
import 'card_parts.dart';
import 'recordings_controller.dart';

/// Hands one capture to a coding agent: pick the agent, check the prompt, launch.
///
/// It runs the handoff itself rather than returning a choice to the caller, and
/// that is the whole reason it is a stateful sheet. A launch has two different
/// successful outcomes — a new session, which received the prompt, and an attach
/// to an agent that was already running, which did not — and the user has to be
/// told which one happened. With no snackbars in this app, the sheet is the only
/// surface that can say so, so it stays open on an attach and closes on a start.
Future<void> showHandoffSheet(
  BuildContext context, {
  required RecordingsController controller,
  required Recording recording,
  String? projectName,
}) async {
  final List<HandoffAgent> agents = controller.handoffAgents(recording);
  if (agents.isEmpty) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext sheetContext) => _HandoffSheet(
      controller: controller,
      recording: recording,
      projectName: projectName,
      agents: agents,
    ),
  );
}

class _HandoffSheet extends StatefulWidget {
  _HandoffSheet({
    required this.controller,
    required this.recording,
    required this.projectName,
    required this.agents,
  });

  final RecordingsController controller;
  final Recording recording;
  final String? projectName;
  final List<HandoffAgent> agents;

  @override
  State<_HandoffSheet> createState() => _HandoffSheetState();
}

class _HandoffSheetState extends State<_HandoffSheet> {
  late final TextEditingController _instruction;
  late String _agentId;
  bool _busy = false;
  AgentHandoffResult? _attached;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The project's default agent, or simply the first: launching the usual
    // agent has to stay one tap, and a sheet that opens with nothing selected
    // would make the common case cost two.
    _agentId = widget.agents
        .firstWhere(
          (HandoffAgent agent) => agent.isDefault,
          orElse: () => widget.agents.first,
        )
        .id;
    _instruction = TextEditingController(
      text: widget.controller.handoffPrompt(widget.recording),
    );
  }

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  Future<void> _launch() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final AgentHandoffResult? result = await widget.controller.handoff(
      widget.recording.id,
      agentId: _agentId,
      instruction: _instruction.text,
    );
    if (!mounted) return;

    if (result == null) {
      setState(() {
        _busy = false;
        _error = widget.controller.error ?? 'The agent session did not open.';
      });
      return;
    }
    if (result.attachedToExistingSession) {
      setState(() {
        _busy = false;
        _attached = result;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final String taskPath = widget.controller.handoffTaskPath(
      widget.recording.id,
    );

    return Container(
      decoration: BoxDecoration(
        color: Console.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: Console.borderStrong),
          left: BorderSide(color: Console.borderStrong),
          right: BorderSide(color: Console.borderStrong),
        ),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottomInset + 24),
      child: SingleChildScrollView(
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
                Expanded(
                  child: Text(
                    'Hand off to an agent',
                    style: TextStyle(
                      fontFamily: ConsoleFont.display,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Console.text,
                    ),
                  ),
                ),
                if (widget.projectName != null)
                  StatusPill(
                    label: widget.projectName!,
                    color: Console.mutedSoft,
                    outlined: true,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              displayNameFor(widget.recording),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ConsoleText.cardMeta,
            ),
            const SizedBox(height: 18),

            SectionHeader(title: 'AGENT'),
            const SizedBox(height: 9),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final HandoffAgent agent in widget.agents)
                  ConsoleChip(
                    label: agent.label.toUpperCase(),
                    selected: agent.id == _agentId,
                    onSelected: _busy
                        ? () {}
                        : () => setState(() => _agentId = agent.id),
                  ),
              ],
            ),
            const SizedBox(height: 18),

            SectionHeader(title: 'OPENING PROMPT'),
            const SizedBox(height: 9),
            // Room for the capture itself, which is what this field now holds.
            // Bounded rather than unbounded: the sheet has to stay reachable
            // above the keyboard on a phone, and a long transcript scrolls.
            ConsoleField(
              controller: _instruction,
              maxLines: 12,
              minLines: 4,
              monospace: true,
              fontSize: 12,
            ),
            const SizedBox(height: 9),
            // The agent is started with the text above. The file is the copy
            // that outlives the session — and the one an *attach* falls back
            // on, since a running agent never receives this prompt.
            Row(
              children: <Widget>[
                Icon(
                  Icons.description_outlined,
                  size: 13,
                  color: Console.dimText,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Sent to the agent as its opening prompt. A copy is also '
                    'written to $taskPath',
                    maxLines: 3,
                    style: ConsoleText.micro,
                  ),
                ),
              ],
            ),

            if (_attached case final AgentHandoffResult result) ...<Widget>[
              const SizedBox(height: 16),
              _AttachedNotice(result: result, instruction: _instruction.text),
            ],
            if (_error case final String message) ...<Widget>[
              const SizedBox(height: 16),
              ErrorBanner(message: message),
            ],

            const SizedBox(height: 18),
            Row(
              children: <Widget>[
                Expanded(
                  child: _LaunchButton(
                    busy: _busy,
                    // After an attach the session is already open and the
                    // capture already closed; the remaining action is to paste
                    // the prompt, not to launch again.
                    label: _attached == null ? 'LAUNCH SESSION' : 'DONE',
                    onTap: _busy
                        ? null
                        : _attached == null
                        ? _launch
                        : () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What an attach means, said plainly, because it is the one outcome that looks
/// like success and is not finished.
class _AttachedNotice extends StatelessWidget {
  _AttachedNotice({required this.result, required this.instruction});

  final AgentHandoffResult result;
  final String instruction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Console.amber.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Console.amber.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.info_outline_rounded, size: 14, color: Console.amber),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'That session was already running',
                  style: ConsoleText.micro.copyWith(color: Console.amber),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            'It was reattached rather than started, so the agent inside it '
            'never received this prompt. Paste it there to begin.',
            style: ConsoleText.micro,
          ),
          const SizedBox(height: 9),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  result.sessionName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConsoleText.micro.copyWith(
                    fontFamily: ConsoleFont.mono,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CopyButton(
                text: instruction,
                tooltip: 'Copy prompt',
                semanticLabel: 'Copy the opening prompt to clipboard',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LaunchButton extends StatelessWidget {
  _LaunchButton({
    required this.busy,
    required this.label,
    required this.onTap,
  });

  final bool busy;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: enabled
                ? Console.accent
                : Console.accent.withValues(alpha: .35),
            borderRadius: BorderRadius.circular(12),
          ),
          // A label rather than a spinner, deliberately: a never-ending
          // animation is a state `pumpAndSettle` can never reach, and this
          // sheet is on the one path a widget test has to be able to drive.
          child: Text(
            busy ? 'LAUNCHING…' : label,
            style: ConsoleText.micro.copyWith(
              color: Console.ink,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
        ),
      ),
    );
  }
}
