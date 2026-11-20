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
      expect(parse.command!.arguments, <String>[
        '--mcp-config=/home/me/t.json',
      ]);
    });

    test('quotes group words and nothing is interpreted', () {
      final AgentCommandParse parse = parseAgentCommand(
        'claude --model "my model" --mcp-config \'\$HOME; rm -rf\'',
        home: '/h',
      );
      expect(
        parse.command!.arguments,
        <String>['--model', 'my model', '--mcp-config', r'$HOME; rm -rf'],
      );
    });

    test('an absolute executable maps by its basename', () {
      final AgentCommandParse parse = parseAgentCommand('/opt/bin/codex');
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
        'claude --mcp-config /t.json --model sonnet --strict-mcp-config',
        'claude --mcp-config=/t.json',
        'codex --model o3',
      ]) {
        expect(parseAgentCommand(line).problem, isNull, reason: line);
        expect(parseAgentCommand(line).command, isNotNull, reason: line);
      }
      expect(argumentsControlApprovals(<String>['--model', 'x']), isFalse);
    });

    test('Windows-style paths and .exe map by basename', () {
      expect(
        parseAgentCommand(r'C:\tools\Claude.EXE').command?.agent,
        ProjectAgent.claude,
      );
      expect(parseAgentCommand('codex.exe').command?.agent, ProjectAgent.codex);
    });

    group('allowlist', () {
      const List<String> bypasses = <String>[
        'codex -c model=o3',
        'codex --config model=o3',
        'codex --config=model=o3',
        'codex -c mcp_servers.todoist.command="sh"',
        'codex -c mcp_servers.todoist.approval_policy=never',
        'codex --config=mcp_servers.todoist.url=https://x.example',
        'codex -p yolo',
        'codex --profile yolo',
        'codex -c profile=yolo',
        'codex -c projects."/x".trust_level="trusted"',
        'codex -c approval_policy=never',
        'codex -c shell_environment_policy.inherit=all',
        'claude --settings /tmp/s.json',
        'claude --settings=/tmp/s.json',
        'claude --setting-sources user',
        'claude --allowedTools mcp__todoist',
        'claude --allowed-tools Bash',
        'claude --disallowedTools x',
        'claude --append-system-prompt hi',
        'claude --add-dir /',
        'claude --model',
        'claude --model --permission-mode',
        'claude --mcp-config',
        'claude somepositional',
        'claude --mcp-config /a.json /b.json',
        'agy --approval-mode=yolo',
        'agy --approval-mode yolo',
        'agy -y',
        'agy --yes',
        'agy --auto-approve',
        'agy --autonomous',
        'agy --model x',
        'claude --strict-mcp-config=true',
      ];
      for (final String line in bypasses) {
        test('refuses: $line', () {
          final AgentCommandParse parse = parseAgentCommand(line);
          expect(parse.command, isNull, reason: line);
          expect(parse.problem, isNotNull, reason: line);
        });
      }

      test('the problem names the offending word and what is allowed', () {
        final String problem = parseAgentCommand(
          'claude --settings x',
        ).problem!;
        expect(problem, contains('--settings'));
        expect(problem, contains('--mcp-config'));
      });

      test('a bare agy is the only agy command', () {
        expect(parseAgentCommand('agy').command, isNotNull);
      });
    });

    test('a relative executable path is refused', () {
      for (final String line in <String>[
        './claude',
        'bin/claude',
        '../claude',
      ]) {
        expect(parseAgentCommand(line).command, isNull, reason: line);
        expect(parseAgentCommand(line).problem, contains('absolute'));
      }
      expect(parseAgentCommand('/usr/bin/claude').command, isNotNull);
      expect(
        parseAgentCommand('~/bin/claude', home: '/home/me').command?.executable,
        '/home/me/bin/claude',
      );
    });

    test(
      'the display predicate also flags what the allowlist never lets in',
      () {
        for (final List<String> args in <List<String>>[
          <String>['--approval-mode=yolo'],
          <String>['-y'],
          <String>['--yes'],
          <String>['--auto-approve'],
          <String>['--profile', 'x'],
          <String>['--settings', 'f'],
          <String>['--setting-sources', 'user'],
          <String>['--allowed-tools', 'x'],
          <String>['-c', 'projects.x.trust_level=trusted'],
          <String>['-c', 'profile=x'],
        ]) {
          expect(
            argumentsControlApprovals(args),
            isTrue,
            reason: args.join(' '),
          );
        }
        expect(
          argumentsControlApprovals(<String>[
            '-p',
            'x',
          ], agent: ProjectAgent.codex),
          isTrue,
        );
        expect(
          argumentsControlApprovals(<String>['-p'], agent: ProjectAgent.claude),
          isFalse,
        );
        expect(argumentsControlApprovals(<String>['--model', 'x']), isFalse);
        // An unknown agent is treated conservatively.
        expect(argumentsControlApprovals(<String>['-p', 'x']), isTrue);
        for (final List<String> args in <List<String>>[
          <String>['--add-dir', '/'],
          <String>['-C', '/'],
          <String>['--cd', '/'],
          <String>['--tools', 'Bash'],
          <String>['--plugin-dir', '/p'],
          <String>['-c', 'shell_environment_policy.inherit=all'],
          <String>['-c', 'default_permissions=x'],
          <String>['--config=features.web_search=true'],
        ]) {
          expect(
            argumentsControlApprovals(args),
            isTrue,
            reason: args.join(' '),
          );
        }
      },
    );
  });
}
