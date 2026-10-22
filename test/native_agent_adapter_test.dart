import 'dart:convert';

import 'package:augustyniak_capture/features/projects/domain/agent_session_launcher.dart';
import 'package:augustyniak_capture/features/projects/domain/native_agent_job.dart';
import 'package:augustyniak_capture/features/projects/domain/native_agent_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Claude uses stdin, stream JSON and exact resume id', () {
    final NativeAgentInvocation invocation = buildNativeAgentInvocation(
      backend: NativeAgentBackend.claude,
      configuredArguments: const <String>['--model', 'sonnet'],
      prompt: '--do not parse me as an option',
      conversationId: 'claude-session-7',
    );

    expect(invocation.stdin, '--do not parse me as an option');
    expect(invocation.arguments, <String>[
      '--model',
      'sonnet',
      '-p',
      '--output-format',
      'stream-json',
      '--verbose',
      '--permission-prompts',
      'none',
      '--resume',
      'claude-session-7',
    ]);
    expect(
      invocation.arguments,
      isNot(contains('--dangerously-skip-permissions')),
    );
  });

  test('Codex puts configured exec options before resume and reads stdin', () {
    final NativeAgentInvocation invocation = buildNativeAgentInvocation(
      backend: NativeAgentBackend.codex,
      configuredArguments: const <String>['--model', 'gpt-5'],
      prompt: 'continue safely',
      conversationId: '019a019e-9590-75f5-b4d7-60a391ada56f',
    );

    expect(invocation.arguments, <String>[
      'exec',
      '--model',
      'gpt-5',
      '--json',
      'resume',
      '019a019e-9590-75f5-b4d7-60a391ada56f',
      '-',
    ]);
    expect(invocation.stdin, 'continue safely');
  });

  test('Antigravity sends one official stream-json user event', () {
    final NativeAgentInvocation invocation = buildNativeAgentInvocation(
      backend: NativeAgentBackend.antigravity,
      configuredArguments: const <String>['--model', 'gemini-3-pro'],
      prompt: 'follow up',
      conversationId: 'conversation-42',
    );

    expect(invocation.arguments, <String>[
      '--model',
      'gemini-3-pro',
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--conversation',
      'conversation-42',
    ]);
    expect(jsonDecode(invocation.stdin.trim()), <String, dynamic>{
      'event': 'user',
      'message': <String, dynamic>{'content': 'follow up'},
    });
  });

  test('parsers extract exact ids, final results and failures', () {
    final NativeAgentOutput claude =
        parseNativeAgentOutput(NativeAgentBackend.claude, const <String>[
          '{"type":"system","subtype":"init","session_id":"claude-1"}',
          '{"type":"result","subtype":"success","result":"done"}',
        ]);
    expect(claude.conversationId, 'claude-1');
    expect(claude.result, 'done');
    expect(claude.terminal, isTrue);

    final NativeAgentOutput
    codex = parseNativeAgentOutput(NativeAgentBackend.codex, const <String>[
      '{"type":"thread.started","thread_id":"codex-1"}',
      '{"type":"item.completed","item":{"type":"agent_message","text":"answer"}}',
      '{"type":"turn.completed"}',
    ]);
    expect(codex.conversationId, 'codex-1');
    expect(codex.result, 'answer');
    expect(codex.terminal, isTrue);

    final NativeAgentOutput
    agy = parseNativeAgentOutput(NativeAgentBackend.antigravity, const <String>[
      '{"event":"init","conversation_id":"agy-1"}',
      '{"event":"result","result":{"conversation_id":"agy-1","status":"ERROR","response":"permission denied"}}',
    ]);
    expect(agy.conversationId, 'agy-1');
    expect(agy.error, 'permission denied');
    expect(agy.terminal, isTrue);
  });

  test('continuation rejects a provider id mismatch', () {
    expect(
      () => parseNativeAgentOutput(NativeAgentBackend.codex, const <String>[
        '{"type":"thread.started","thread_id":"different"}',
      ], expectedConversationId: 'expected'),
      throwsA(isA<AgentSessionLaunchException>()),
    );
  });

  test('Gemini native background is explicit unavailable', () {
    expect(
      () => nativeBackendFor(ProjectAgent.gemini),
      throwsA(
        isA<AgentSessionLaunchException>().having(
          (AgentSessionLaunchException error) => error.message,
          'message',
          contains('not available'),
        ),
      ),
    );
  });

  test('malformed persisted job handles degrade instead of throwing', () {
    expect(
      NativeAgentJobHandle.fromJson(<String, dynamic>{
        'id': 42,
        'backend': 'codex',
      }),
      isNull,
    );
  });
}
