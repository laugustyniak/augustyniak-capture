import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/agent_handoff.dart';
import '../domain/assistant_target.dart';
import '../domain/capture_sender.dart';
import '../domain/recording.dart';
import 'card_parts.dart';
import 'recordings_controller.dart';

/// The **Send to…** sheet: one prompt, and every place this machine can put it.
///
/// Terminal agents (only when the capture's project offers some), Claude
/// Desktop, the web assistants, the system share sheet and the clipboard. It
/// runs the send itself rather than returning a choice to the caller, and that
/// is the whole reason it is a stateful sheet: the outcomes differ and the user
/// has to be told which one happened. A launch has two successful outcomes — a
/// new session, which received the prompt, and an attach to an agent that was
/// already running, which did not. A web, share or copy send cannot confirm
/// delivery at all, so the sheet stays open to say where the text went and to
/// ask whether the capture is done. With no snackbars in this app, the sheet is
/// the only surface that can say so.
///
/// Opens with an empty agent list: a capture with no project still has Web and
/// Copy. The callers decide whether to show the control at all.
Future<void> showHandoffSheet(
  BuildContext context, {
  required RecordingsController controller,
  required Recording recording,
  String? projectName,
}) async {
  final List<HandoffAgent> agents = controller.handoffAgents(recording);
  // Read before the sheet exists so it never has to render a loading state:
  // the probe for a `claude://` handler is the only slow part and it is short.
  final List<SendTarget> targets = await controller.sendTargets();
  if (agents.isEmpty && targets.isEmpty) return;
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext sheetContext) => _HandoffSheet(
      controller: controller,
      recording: recording,
      projectName: projectName,
      agents: agents,
      targets: targets,
    ),
  );
}

class _HandoffSheet extends StatefulWidget {
  _HandoffSheet({
    required this.controller,
    required this.recording,
    required this.projectName,
    required this.agents,
    required this.targets,
  });

  final RecordingsController controller;
  final Recording recording;
  final String? projectName;
  final List<HandoffAgent> agents;
  final List<SendTarget> targets;

  @override
  State<_HandoffSheet> createState() => _HandoffSheetState();
}

class _HandoffSheetState extends State<_HandoffSheet> {
  late final TextEditingController _instruction;
  String _agentId = '';
  bool _busy = false;
  bool _launching = false;
  AgentHandoffResult? _attached;
  SendOutcome? _sent;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The project's default agent, or simply the first: launching the usual
    // agent has to stay one tap, and a sheet that opens with nothing selected
    // would make the common case cost two.
    if (widget.agents.isNotEmpty) {
      _agentId = widget.agents
          .firstWhere(
            (HandoffAgent agent) => agent.isDefault,
            orElse: () => widget.agents.first,
          )
          .id;
    }
    _instruction = TextEditingController(
      text: widget.controller.handoffPrompt(widget.recording),
    );
  }

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  Future<void> _send(SendTarget target) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final SendOutcome? outcome = await widget.controller.send(
      widget.recording.id,
      target,
      _instruction.text,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (outcome != null) {
        _sent = outcome;
      } else if (widget.controller.error case final String message) {
        // A dismissed share sheet leaves no error, and the sheet no message.
        _error = message;
      }
    });
  }

  Future<void> _markDone() async {
    await widget.controller.toggleProcessed(widget.recording.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _launch() async {
    setState(() {
      _busy = true;
      _launching = true;
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
        _launching = false;
        _error = widget.controller.error ?? 'The agent session did not open.';
      });
      return;
    }
    if (result.attachedToExistingSession) {
      setState(() {
        _busy = false;
        _launching = false;
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
                    'Send to…',
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

            SectionHeader(title: 'PROMPT'),
            const SizedBox(height: 9),
            // Room for the capture itself, which is what this field holds and
            // what every target below receives, edited or not. Bounded rather
            // than unbounded: the sheet has to stay reachable above the
            // keyboard on a phone, and a long transcript scrolls.
            ConsoleField(
              controller: _instruction,
              maxLines: 12,
              minLines: 4,
              monospace: true,
              fontSize: 12,
            ),
            const SizedBox(height: 18),

            if (_sent case final SendOutcome outcome) ...<Widget>[
              _SentNotice(
                outcome: outcome,
                onMarkDone: _markDone,
                onKeep: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 18),
            ],
            if (_error case final String message) ...<Widget>[
              ErrorBanner(message: message),
              const SizedBox(height: 18),
            ],

            if (widget.agents.isNotEmpty) ..._terminalGroup(taskPath),
            ..._targetGroups(),
          ],
        ),
      ),
    );
  }

  /// Existing agents, unchanged in behaviour: launch, attach notice, close on a
  /// new session.
  List<Widget> _terminalGroup(String taskPath) => <Widget>[
    SectionHeader(title: 'TERMINAL'),
    const SizedBox(height: 9),
    // **The label is the point of this group.** This path opens one CLI in one
    // terminal on this machine and then loses sight of it: no second prompt
    // reaches the running session, and nothing ever reports back. A project
    // bound to the control plane never gets here — `ProjectAgentHandoff`
    // refuses it — so a group that is shown is by definition the unsupervised
    // path, and saying so is what stops the two reading as the same action.
    Row(
      children: <Widget>[
        Icon(Icons.desktop_windows_outlined, size: 13, color: Console.amber),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Local session — not supervised. It runs on this machine '
            'and reports nothing back.',
            style: ConsoleText.micro.copyWith(color: Console.amber),
          ),
        ),
      ],
    ),
    const SizedBox(height: 12),
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
    const SizedBox(height: 9),
    // The agent is started with the prompt above. The file is the copy that
    // outlives the session — and the one an *attach* falls back on, since a
    // running agent never receives this prompt.
    Row(
      children: <Widget>[
        Icon(Icons.description_outlined, size: 13, color: Console.dimText),
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
    const SizedBox(height: 14),
    _LaunchButton(
      busy: _launching,
      // After an attach the session is already open and the capture already
      // closed; the remaining action is to paste the prompt, not to launch
      // again.
      label: _attached == null ? 'LAUNCH SESSION' : 'DONE',
      onTap: _busy
          ? null
          : _attached == null
          ? _launch
          : () => Navigator.of(context).pop(),
    ),
    const SizedBox(height: 22),
  ];

  /// Claude Desktop, Web, Share and Copy, in the order the sender listed them
  /// (Android puts Share first). A header is printed where the group changes.
  List<Widget> _targetGroups() {
    final List<Widget> out = <Widget>[];
    String? group;
    for (final SendTarget target in widget.targets) {
      final String next = _groupOf(target);
      if (next != group) {
        if (group != null) out.add(const SizedBox(height: 14));
        out.add(SectionHeader(title: next));
        out.add(const SizedBox(height: 9));
        group = next;
      }
      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _TargetTile(
            label: _labelOf(target),
            detail: _detailOf(target),
            onTap: _busy ? null : () => _send(target),
          ),
        ),
      );
    }
    return out;
  }

  static String _groupOf(SendTarget target) => switch (target) {
    AssistantSendTarget(:final AssistantTarget target) =>
      target.isWeb ? 'WEB' : 'CLAUDE DESKTOP',
    ShareSendTarget() => 'SHARE',
    CopySendTarget() => 'COPY',
  };

  static String _labelOf(SendTarget target) => switch (target) {
    AssistantSendTarget(:final AssistantTarget target) => target.label,
    ShareSendTarget() => 'System share sheet',
    CopySendTarget() => 'Copy prompt',
  };

  /// Where the text goes, and what happens when it gets there. Sending
  /// publishes the capture to a third party, so the destination is on the
  /// button, and a target that sends the moment it opens says so — the prompt
  /// field above is then the user's last chance to edit.
  static String _detailOf(SendTarget target) => switch (target) {
    AssistantSendTarget(:final AssistantTarget target) =>
      !target.supportsPrefill
          ? '${target.domain} · you paste the prompt'
          : target.autoSubmits
          ? '${target.domain} · sends immediately'
          : '${target.domain} · opens with the prompt filled in',
    ShareSendTarget() => 'Pick any app you have installed',
    CopySendTarget() => 'Nothing leaves this device',
  };
}

/// What a completed send says, and the two things the user can do about the
/// capture. Delivery is unconfirmed, so closing it is their call.
class _SentNotice extends StatelessWidget {
  _SentNotice({
    required this.outcome,
    required this.onMarkDone,
    required this.onKeep,
  });

  final SendOutcome outcome;
  final VoidCallback onMarkDone;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final String target = outcome.record.target;
    final bool copyOnly = target == 'clipboard';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Console.green.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Console.green.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.check_circle_outline, size: 14, color: Console.green),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  copyOnly ? 'Copied to clipboard' : 'Sent to $target',
                  style: ConsoleText.micro.copyWith(color: Console.green),
                ),
              ),
            ],
          ),
          if (outcome.copiedToClipboard && !copyOnly) ...<Widget>[
            const SizedBox(height: 7),
            Text(
              'Prompt copied — paste it into ${_serviceOf(target)}',
              style: ConsoleText.micro,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: _LaunchButton(
                  busy: false,
                  label: 'MARK DONE',
                  onTap: onMarkDone,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _LaunchButton(
                  busy: false,
                  label: 'KEEP ON DESK',
                  onTap: onKeep,
                  outlined: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// `ChatGPT · web` → `ChatGPT`.
  static String _serviceOf(String target) => target.split(' · ').first;
}

/// One destination: its name, and where it goes.
class _TargetTile extends StatelessWidget {
  _TargetTile({required this.label, required this.detail, required this.onTap});

  final String label;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: '$label, $detail',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Opacity(
          opacity: enabled ? 1 : .5,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: Console.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Console.borderStrong),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: ConsoleFont.display,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Console.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(detail, style: ConsoleText.micro),
              ],
            ),
          ),
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
    this.outlined = false,
  });

  final bool busy;
  final String label;
  final VoidCallback? onTap;

  /// The quieter of two side-by-side actions.
  final bool outlined;

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
            color: outlined
                ? null
                : enabled
                ? Console.accent
                : Console.accent.withValues(alpha: .35),
            border: outlined ? Border.all(color: Console.borderStrong) : null,
            borderRadius: BorderRadius.circular(12),
          ),
          // A label rather than a spinner, deliberately: a never-ending
          // animation is a state `pumpAndSettle` can never reach, and this
          // sheet is on the one path a widget test has to be able to drive.
          child: Text(
            busy ? 'LAUNCHING…' : label,
            style: ConsoleText.micro.copyWith(
              color: outlined ? Console.text : Console.ink,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
        ),
      ),
    );
  }
}
