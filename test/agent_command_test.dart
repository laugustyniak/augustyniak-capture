import 'package:augustyniak_capture/features/projects/domain/agent_command.dart';
import 'package:augustyniak_capture/features/projects/domain/agent_session_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseAgentCommand', () {
    test('blank is neither a command nor a problem', () {
      final AgentCommandParse parse = parseAgentCommand('   ');
      expect(parse.command, isNull);
      expect(parse.problem, isNull);
    });

    test('splits into an executable and arguments, expanding ~/', () {
      final AgentCommandParse parse = parseAgentCommand(
        'claude --mcp-config ~/.claude/todoist.json',
        home: '/home/me',
      );
      expect(parse.problem, isNull);
      expect(parse.command!.agent, ProjectAgent.claude);
      expect(parse.command!.executable, 'claude');
      expect(parse.command!.arguments, <String>[
        '--mcp-config',
        '/home/me/.claude/todoist.json',
      ]);
    });

    test('expands ~/ after an equals sign', () {
      final AgentCommandParse parse = parseAgentCommand(
        'claude --mcp-config=~/t.json',
        home: '/home/me',
      );
      expect(parse.command!.arguments, <String>['--mcp-config=/home/me/t.json']);
    });

    test('quotes group words and nothing is interpreted', () {
      final AgentCommandParse parse = parseAgentCommand(
        'claude --append-system-prompt "use Todoist only" \'\$HOME; rm -rf\'',
        home: '/h',
      );
      expect(parse.command!.arguments, <String>[
        '--append-system-prompt',
        'use Todoist only',
        r'$HOME; rm -rf',
      ]);
    });

    test('an absolute executable maps by its basename', () {
      final AgentCommandParse parse = parseAgentCommand(
        '/opt/bin/codex --foo',
      );
      expect(parse.command!.agent, ProjectAgent.codex);
      expect(parse.command!.executable, '/opt/bin/codex');
    });

    test('agy maps to antigravity', () {
      expect(parseAgentCommand('agy').command!.agent, ProjectAgent.antigravity);
    });

    test('an executable that has no native background mode is a problem', () {
      expect(parseAgentCommand('gemini').problem, isNotNull);
      expect(parseAgentCommand('my-wrapper --x').problem, isNotNull);
      expect(parseAgentCommand('my-wrapper --x').command, isNull);
    });

    test('an unbalanced quote is a problem', () {
      expect(parseAgentCommand('claude "oops').problem, isNotNull);
    });

    test('a permission-bypass flag is refused, whatever the spelling', () {
      for (final String flag in <String>[
        '--dangerously-skip-permissions',
        '--dangerously-bypass-approvals-and-sandbox',
        '--yolo',
      ]) {
        final AgentCommandParse parse = parseAgentCommand('claude $flag');
        expect(parse.command, isNull, reason: flag);
        expect(parse.problem, isNotNull, reason: flag);
      }
    });

    const List<List<String>> approvalControls = <List<String>>[
      <String>['--allow-dangerously-skip-permissions'],
      <String>['--allow-dangerously-anything'],
      <String>['--permission-mode', 'bypassPermissions'],
      <String>['--permission-mode=acceptEdits'],
      <String>['--permission-mode', 'default'],
      <String>['--full-auto'],
      <String>['-s', 'danger-full-access'],
      <String>['-sdanger-full-access'],
      <String>['--sandbox', 'read-only'],
      <String>['--sandbox=workspace-write'],
      <String>['-a', 'never'],
      <String>['--ask-for-approval', 'never'],
      <String>['--ask-for-approval=never'],
      <String>['-c', 'approval_policy="never"'],
      <String>['-c', 'sandbox_mode=danger-full-access'],
      <String>['--config', 'approval_policy=never'],
      <String>['--config=sandbox_mode=x'],
      <String>['-capproval_policy=never'],
      <String>['-c', 'SANDBOX_MODE=x'],
    ];

    for (final List<String> flags in approvalControls) {
      test('refuses the approval or sandbox control ${flags.join(' ')}', () {
        for (final String exe in <String>['claude', 'codex']) {
          final AgentCommandParse parse = parseAgentCommand(
            '$exe ${flags.join(' ')}',
          );
          expect(parse.command, isNull, reason: flags.join(' '));
          expect(parse.problem, isNotNull);
        }
        expect(argumentsControlApprovals(flags), isTrue);
      });
    }

    test('an unrelated -c value and ordinary options are allowed', () {
      for (final String line in <String>[
        'codex -c model="o3"',
        'codex --config model=o3',
        'claude --mcp-config /t.json --allowedTools mcp__todoist',
        'claude --model sonnet --append-system-prompt "be brief"',
      ]) {
        expect(parseAgentCommand(line).problem, isNull, reason: line);
        expect(parseAgentCommand(line).command, isNotNull, reason: line);
      }
      expect(argumentsControlApprovals(<String>['--model', 'x']), isFalse);
    });

    test('Windows-style paths and .exe map by basename', () {
      expect(
        parseAgentCommand(r'C:\tools\Claude.EXE --x').command?.agent,
        ProjectAgent.claude,
      );
      expect(parseAgentCommand('codex.exe').command?.agent, ProjectAgent.codex);
    });
  });
}
