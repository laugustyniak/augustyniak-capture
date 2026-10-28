import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../projects/domain/agent_command.dart';
import '../../recordings/domain/smart_route.dart';
import 'settings_controller.dart';

/// The SMART route button's two settings (#386): whether an intent with
/// effects waits for one tap, and the agent command the Todoist intent runs.
///
/// Stateful for the same reason `CommandSection` is: the field has to survive
/// this controller's notifications, and a background save must never overwrite
/// what somebody is halfway through typing.
class SmartRouteSection extends StatefulWidget {
  SmartRouteSection({super.key, required this.controller});

  final SettingsController controller;

  @override
  State<SmartRouteSection> createState() => _SmartRouteSectionState();
}

class _SmartRouteSectionState extends State<SmartRouteSection> {
  late final TextEditingController _command = TextEditingController(
    text: _stored,
  );
  final FocusNode _focus = FocusNode();
  late String _synced = _stored;

  String get _stored => widget.controller.todoistAgentCommand;
  bool get _dirty => _command.text.trim() != _synced.trim();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _dirty) _commit();
    });
  }

  @override
  void didUpdateWidget(SmartRouteSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_stored != _synced && !_dirty) {
      _synced = _stored;
      _command.text = _synced;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _command.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    final String value = _command.text.trim();
    await widget.controller.setTodoistAgentCommand(value);
    if (!mounted) return;
    setState(() => _synced = value);
  }

  @override
  Widget build(BuildContext context) {
    final bool confirm =
        widget.controller.smartRouteConfirm == SmartRouteConfirm.confirmEffects;
    // Judged live from the field, so a refused command is explained while the
    // user is still looking at it rather than as a missing intent later.
    final AgentCommandParse parse = parseAgentCommand(_command.text);
    final bool active = parse.command != null && !_dirty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHeader(title: 'SMART ROUTE'),
        const SizedBox(height: 12),
        ConsoleCard(
          accent: active ? Console.accent : Console.border,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'One button reads what a capture asks for — search, analysis, '
                'next actions, verification, a new agent session, a Todoist '
                'task, or a plain note for the project inbox — and routes it. '
                'It uses the enrichment model, or a built-in keyword check '
                'when there is none.',
                style: TextStyle(
                  color: Console.mutedSoft,
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'ASK BEFORE ANYTHING THAT STARTS AN AGENT',
                      style: ConsoleText.micro.copyWith(
                        color: Console.muted,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .6,
                      ),
                    ),
                  ),
                  Switch(
                    key: const ValueKey<String>('smart-route-confirm'),
                    value: confirm,
                    onChanged: (bool value) async {
                      await widget.controller.setSmartRouteConfirm(
                        value
                            ? SmartRouteConfirm.confirmEffects
                            : SmartRouteConfirm.auto,
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ),
              Text(
                confirm
                    ? 'A one-line decision and one tap before an agent starts. '
                          'Plain notes still go straight to the inbox.'
                    : 'Fully automatic: the capture is classified and sent '
                          'with no question.',
                style: TextStyle(
                  color: Console.mutedSoft,
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'TODOIST AGENT COMMAND',
                style: ConsoleText.micro.copyWith(color: Console.dimText),
              ),
              const SizedBox(height: 6),
              ConsoleField(
                key: const ValueKey<String>('todoist-agent-command'),
                controller: _command,
                focusNode: _focus,
                monospace: true,
                fontSize: 12,
                textInputAction: TextInputAction.done,
                onSubmitted: (String _) => _commit(),
                onChanged: (String _) => setState(() {}),
                hintText: 'claude --mcp-config ~/.claude/todoist.json',
              ),
              const SizedBox(height: 8),
              Text(
                'Runs in the background for "add a task" captures. Typed as '
                'arguments, not a shell line: a shell alias is not visible to '
                'an app, so spell out what the alias expands to. The first '
                'word must be claude, codex or agy; ~/ is expanded; '
                'permission-bypass flags are refused. Include whatever gives '
                'that agent Todoist access (an MCP config, allowed tools). '
                'Empty turns the Todoist intent off, and such captures go to '
                'the inbox.',
                style: TextStyle(
                  color: Console.mutedSoft,
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              if (_dirty) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  'UNSAVED',
                  style: ConsoleText.micro.copyWith(color: Console.amber),
                ),
              ],
              if (parse.problem != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  parse.problem!,
                  style: ConsoleText.micro.copyWith(color: Console.red),
                ),
              ] else if (active) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  'TODOIST INTENT ON · ${parse.command!.agent.executable}',
                  style: ConsoleText.micro.copyWith(color: Console.accent),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
