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
    this.observedConversationIds = const <String>[],
    this.result,
    this.error,
    this.terminal = false,
    this.promptAccepted = false,
    this.errorBeforePromptAccepted = false,
  });

  final String? conversationId;
  final List<String> observedConversationIds;
  final String? result;
  final String? error;
  final bool terminal;
  final bool promptAccepted;
  final bool errorBeforePromptAccepted;
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
  final List<String> observedConversationIds = <String>[];
  String? result;
  String? error;
  bool terminal = false;
  bool promptAccepted = false;
  bool errorBeforePromptAccepted = false;
  void observeConversationId(Object? value) {
    final String? id = _nonEmpty(value);
    if (id == null) return;
    conversationId = id;
    if (!observedConversationIds.contains(id)) {
      observedConversationIds.add(id);
    }
  }

  void observeError(String value) {
    if (!promptAccepted) errorBeforePromptAccepted = true;
    error = value;
  }

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
          observeConversationId(decoded['session_id']);
        }
        if (decoded['type'] == 'assistant') {
          final String? assistantError = _nonEmpty(decoded['error']);
          if (assistantError == null) {
            promptAccepted = true;
          } else {
            observeError('Claude API error: $assistantError.');
          }
        }
        if (decoded['type'] == 'result') {
          terminal = true;
          result = _nonEmpty(decoded['result']);
          final Object? denials = decoded['permission_denials'];
          if (decoded['is_error'] == true || decoded['subtype'] != 'success') {
            observeError(
              _nonEmpty(decoded['error']) ??
                  _nonEmpty(decoded['result']) ??
                  (denials is List && denials.isNotEmpty
                      ? 'Permission denied: ${denials.join(', ')}'
                      : 'Claude task failed.'),
            );
          } else if (denials is List && denials.isNotEmpty) {
            observeError('Permission denied: ${denials.join(', ')}');
          } else {
            promptAccepted = true;
          }
        }
      case NativeAgentBackend.codex:
        if (decoded['type'] == 'thread.started') {
          observeConversationId(decoded['thread_id']);
        }
        if (decoded['type'] == 'turn.started') {
          promptAccepted = true;
        }
        if (decoded['type'] == 'item.completed') {
          final Object? item = decoded['item'];
          if (item is Map<String, dynamic> && item['type'] == 'agent_message') {
            result = _nonEmpty(item['text']);
          }
        }
        if (decoded['type'] == 'turn.completed') {
          terminal = true;
          promptAccepted = true;
        }
        if (decoded['type'] == 'turn.failed') {
          terminal = true;
          final Object? failure = decoded['error'];
          observeError(
            failure is Map<String, dynamic>
                ? _nonEmpty(failure['message']) ?? 'Codex task failed.'
                : _nonEmpty(failure) ?? 'Codex task failed.',
          );
        }
      case NativeAgentBackend.antigravity:
        if (decoded['event'] == 'init') {
          observeConversationId(decoded['conversation_id']);
        }
        if (decoded['event'] == 'step_update') {
          final Object? step = decoded['step_update'];
          if (step is Map<String, dynamic> &&
              step['step_type'] == 'user_input' &&
              step['state'] == 'DONE') {
            promptAccepted = true;
          }
        }
        if (decoded['event'] == 'result') {
          terminal = true;
          final Object? value = decoded['result'];
          if (value is Map<String, dynamic>) {
            observeConversationId(value['conversation_id']);
            final String? response = _nonEmpty(value['response']);
            if (value['status'] == 'SUCCESS') {
              result = response;
              promptAccepted = true;
            } else {
              observeError(
                _nonEmpty(value['error']) ??
                    response ??
                    'Antigravity task failed.',
              );
            }
          }
        }
    }
  }
  String? mismatchedId;
  if (expectedConversationId != null) {
    for (final String id in observedConversationIds) {
      if (id != expectedConversationId) {
        mismatchedId = id;
        break;
      }
    }
  }
  if (mismatchedId != null) {
    throw AgentSessionLaunchException(
      'The provider resumed `$mismatchedId` instead of the requested '
      '`$expectedConversationId`.',
    );
  }
  return NativeAgentOutput(
    conversationId: conversationId,
    observedConversationIds: List<String>.unmodifiable(observedConversationIds),
    result: result,
    error: error,
    terminal: terminal,
    promptAccepted: promptAccepted,
    errorBeforePromptAccepted: errorBeforePromptAccepted,
  );
}

String? _nonEmpty(Object? value) {
  if (value is! String) return null;
  final String normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}
