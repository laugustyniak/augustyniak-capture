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
  });
}
