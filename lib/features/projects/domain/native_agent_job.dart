import 'dart:convert';

import 'agent_session_launcher.dart';
import 'native_agent_types.dart';

class NativeAgentInvocation {
  const NativeAgentInvocation({required this.arguments, required this.stdin});

  final List<String> arguments;
  final String stdin;
}

class NativeAgentOutput {
  const NativeAgentOutput({
    this.conversationId,
    this.result,
    this.error,
    this.terminal = false,
  });

  final String? conversationId;
  final String? result;
  final String? error;
  final bool terminal;
}

NativeAgentBackend nativeBackendFor(ProjectAgent agent) => switch (agent) {
  ProjectAgent.claude => NativeAgentBackend.claude,
  ProjectAgent.codex => NativeAgentBackend.codex,
  ProjectAgent.antigravity => NativeAgentBackend.antigravity,
  ProjectAgent.gemini => throw const AgentSessionLaunchException(
    'Gemini CLI background jobs are not available. Start it in a window.',
  ),
};

NativeAgentInvocation buildNativeAgentInvocation({
  required NativeAgentBackend backend,
  required List<String> configuredArguments,
  required String prompt,
  String? conversationId,
}) {
  return switch (backend) {
    NativeAgentBackend.claude => NativeAgentInvocation(
      arguments: <String>[
        ...configuredArguments,
        '-p',
        '--output-format',
        'stream-json',
        '--verbose',
        '--permission-prompts',
        'none',
        if (conversationId != null) ...<String>['--resume', conversationId],
      ],
      stdin: prompt,
    ),
    NativeAgentBackend.codex => NativeAgentInvocation(
      arguments: <String>[
        'exec',
        ...configuredArguments,
        '--json',
        if (conversationId != null) ...<String>['resume', conversationId],
        '-',
      ],
      stdin: prompt,
    ),
    NativeAgentBackend.antigravity => NativeAgentInvocation(
      arguments: <String>[
        ...configuredArguments,
        '--input-format',
        'stream-json',
        '--output-format',
        'stream-json',
        if (conversationId != null) ...<String>[
          '--conversation',
          conversationId,
        ],
      ],
      stdin:
          '${jsonEncode(<String, dynamic>{
            'event': 'user',
            'message': <String, dynamic>{'content': prompt},
          })}\n',
    ),
  };
}

NativeAgentOutput parseNativeAgentOutput(
  NativeAgentBackend backend,
  Iterable<String> lines, {
  String? expectedConversationId,
}) {
  String? conversationId;
  String? result;
  String? error;
  bool terminal = false;
  for (final String line in lines) {
    if (line.trim().isEmpty) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, dynamic>) continue;
    switch (backend) {
      case NativeAgentBackend.claude:
        if (decoded['type'] == 'system' && decoded['subtype'] == 'init') {
          conversationId = _nonEmpty(decoded['session_id']);
        }
        if (decoded['type'] == 'result') {
          terminal = true;
          result = _nonEmpty(decoded['result']);
          final Object? denials = decoded['permission_denials'];
          if (decoded['is_error'] == true || decoded['subtype'] != 'success') {
            error =
                _nonEmpty(decoded['error']) ??
                _nonEmpty(decoded['result']) ??
                (denials is List && denials.isNotEmpty
                    ? 'Permission denied: ${denials.join(', ')}'
                    : 'Claude task failed.');
          } else if (denials is List && denials.isNotEmpty) {
            error = 'Permission denied: ${denials.join(', ')}';
          }
        }
      case NativeAgentBackend.codex:
        if (decoded['type'] == 'thread.started') {
          conversationId = _nonEmpty(decoded['thread_id']);
        }
        if (decoded['type'] == 'item.completed') {
          final Object? item = decoded['item'];
          if (item is Map<String, dynamic> && item['type'] == 'agent_message') {
            result = _nonEmpty(item['text']);
          }
        }
        if (decoded['type'] == 'turn.completed') terminal = true;
        if (decoded['type'] == 'turn.failed') {
          terminal = true;
          final Object? failure = decoded['error'];
          error = failure is Map<String, dynamic>
              ? _nonEmpty(failure['message']) ?? 'Codex task failed.'
              : _nonEmpty(failure) ?? 'Codex task failed.';
        }
      case NativeAgentBackend.antigravity:
        if (decoded['event'] == 'init') {
          conversationId = _nonEmpty(decoded['conversation_id']);
        }
        if (decoded['event'] == 'result') {
          terminal = true;
          final Object? value = decoded['result'];
          if (value is Map<String, dynamic>) {
            conversationId =
                _nonEmpty(value['conversation_id']) ?? conversationId;
            final String? response = _nonEmpty(value['response']);
            if (value['status'] == 'SUCCESS') {
              result = response;
            } else {
              error = response ?? 'Antigravity task failed.';
            }
          }
        }
    }
  }
  if (expectedConversationId != null &&
      conversationId != null &&
      conversationId != expectedConversationId) {
    throw AgentSessionLaunchException(
      'The provider resumed `$conversationId` instead of the requested '
      '`$expectedConversationId`.',
    );
  }
  return NativeAgentOutput(
    conversationId: conversationId,
    result: result,
    error: error,
    terminal: terminal,
  );
}

String? _nonEmpty(Object? value) {
  if (value is! String) return null;
  final String normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}
