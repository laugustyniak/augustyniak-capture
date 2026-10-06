import 'dart:async';
import 'dart:convert';

import 'capture_tools.dart';

/// Newline-delimited JSON-RPC 2.0 over any line stream and sink, so a test
/// drives it without a process. Nothing here touches stdout: the caller owns
/// the sink, because stdout carries protocol JSON and nothing else.
class McpServer {
  McpServer(this._tools, {void Function(String)? log})
    : _log = log ?? ((String _) {});

  final CaptureTools _tools;
  final void Function(String) _log;

  static const List<String> _supportedVersions = <String>[
    '2025-06-18',
    '2025-03-26',
    '2024-11-05',
  ];

  /// [serve] over raw bytes. Malformed UTF-8 becomes U+FFFD inside the line
  /// that carries it — the strict decoder would throw and end the loop, and a
  /// stdio server that dies on one bad byte takes the agent's tools with it.
  Future<void> serveBytes(
    Stream<List<int>> bytes,
    void Function(String) write,
  ) => serve(
    bytes
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter()),
    write,
  );

  /// Answers each line in order until [lines] ends. One bad line never ends
  /// the loop.
  Future<void> serve(Stream<String> lines, void Function(String) write) async {
    await for (final String line in lines) {
      if (line.trim().isEmpty) continue;
      final Map<String, dynamic>? response = await _handleLine(line);
      if (response != null) write(jsonEncode(response));
    }
  }

  Future<Map<String, dynamic>?> _handleLine(String line) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return _error(null, -32700, 'Parse error');
    }
    if (decoded is! Map<String, dynamic> || decoded['method'] is! String) {
      return _error(null, -32600, 'Invalid request');
    }
    final Object? id = decoded['id'];
    final bool isNotification = !decoded.containsKey('id');
    final String method = decoded['method'] as String;
    final Object? params = decoded['params'];
    try {
      final Object? result = await _dispatch(
        method,
        params is Map<String, dynamic> ? params : const <String, dynamic>{},
      );
      if (isNotification) return null;
      return <String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result};
    } on InvalidParams catch (e) {
      return isNotification ? null : _error(id, -32602, e.message);
    } on _UnknownMethod {
      return isNotification ? null : _error(id, -32601, 'Method not found');
    } catch (e) {
      // The detail may name a path; the client gets a fixed message.
      _log('internal error handling $method: $e');
      return isNotification ? null : _error(id, -32603, 'Internal error');
    }
  }

  Future<Object?> _dispatch(String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'initialize':
        final Object? asked = params['protocolVersion'];
        return <String, dynamic>{
          'protocolVersion': _supportedVersions.contains(asked)
              ? asked
              : _supportedVersions.first,
          'capabilities': <String, dynamic>{'tools': <String, dynamic>{}},
          'serverInfo': <String, dynamic>{
            'name': 'augustyniak-capture',
            'version': '0.1.0',
          },
        };
      case 'ping':
        return <String, dynamic>{};
      case 'tools/list':
        return <String, dynamic>{'tools': _tools.definitions};
      case 'tools/call':
        final Object? name = params['name'];
        final Object? args = params['arguments'];
        if (name is! String) throw InvalidParams('Missing tool name');
        return _tools.call(
          name,
          args is Map<String, dynamic> ? args : const <String, dynamic>{},
        );
      default:
        if (method.startsWith('notifications/')) return null;
        throw _UnknownMethod();
    }
  }

  Map<String, dynamic> _error(Object? id, int code, String message) =>
      <String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, dynamic>{'code': code, 'message': message},
      };
}

class _UnknownMethod implements Exception {}
