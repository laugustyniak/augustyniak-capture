enum NativeAgentBackend { claude, codex, antigravity }

enum NativeAgentJobStatus {
  starting,
  running,
  stopping,
  completed,
  failed,
  stopped,
  lost,
}

class NativeAgentJobHandle {
  const NativeAgentJobHandle({required this.id, required this.backend});

  final String id;
  final NativeAgentBackend backend;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'backend': backend.name,
  };

  static NativeAgentJobHandle? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final Object? rawId = json['id'];
    final String? id = rawId is String ? rawId : null;
    final NativeAgentBackend? backend = NativeAgentBackend.values
        .where((NativeAgentBackend value) => value.name == json['backend'])
        .firstOrNull;
    if (id == null || !isSafeNativeAgentJobId(id) || backend == null) {
      return null;
    }
    return NativeAgentJobHandle(id: id, backend: backend);
  }
}

bool isSafeNativeAgentJobId(String id) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
).hasMatch(id);
