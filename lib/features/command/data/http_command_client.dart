import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/http/provider_failure.dart';
import '../domain/command_client.dart';

/// Reads the fleet over the aggregator's HTTP API.
///
/// Deliberately the same shape as `HttpChatEnrichmentService`: a base URI, an
/// optional bearer token, one `http.Client` seam so the suite never opens a
/// socket, and a defensive parse. What is different is the failure policy —
/// this one is answering a picker, so it throws on anything it cannot read
/// rather than degrading, because an empty list and an unreachable control
/// plane look identical in a dropdown and only one of them is worth retrying.
class HttpCommandClient implements CommandClient {
  HttpCommandClient({
    required this.baseUrl,
    this.bearerToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final String? bearerToken;
  final http.Client _client;

  /// A picker the user is waiting in front of, not a background job — so this
  /// is much shorter than the OCR timeout. A control plane that has not
  /// answered in ten seconds is down as far as binding is concerned.
  static const Duration requestTimeout = Duration(seconds: 10);

  @override
  bool get isConfigured => true;

  @override
  Future<List<CommandHost>> hosts() async {
    final List<dynamic> rows = await _getList(
      _resolve(<String>['api', 'hosts']),
      what: 'Listing Command hosts',
      key: 'hosts',
    );
    return rows.map(CommandHost.fromJson).whereType<CommandHost>().toList();
  }

  @override
  Future<List<CommandWorkspace>> workspaces(String hostId) async {
    final List<dynamic> rows = await _getList(
      _resolve(<String>['api', hostId, 'workspaces']),
      what: 'Listing Command workspaces',
      key: 'workspaces',
    );
    return rows
        .map(CommandWorkspace.fromJson)
        .whereType<CommandWorkspace>()
        .toList();
  }

  @override
  Future<CommandBrief> putBrief({
    required String host,
    required String workspace,
    required String captureId,
    required String content,
  }) async {
    final Map<String, dynamic> body = await _send(
      'PUT',
      _resolve(<String>['api', host, 'workspaces', workspace, 'briefs']),
      what: 'Filing the Command brief',
      payload: <String, dynamic>{
        // Snake case because the other end owns this contract — see RFC-0008 in
        // the Command repository. This app's own JSON is camel case and stays
        // that way; matching it here would simply be wrong on the wire.
        'capture_id': captureId,
        'content': content,
      },
    );
    final CommandBrief? brief = CommandBrief.fromJson(body);
    if (brief == null) {
      throw const FormatException(
        'The control plane accepted the brief but named no brief id.',
      );
    }
    return brief;
  }

  @override
  Future<CommandSession> startSession({
    required String host,
    required String workspace,
    required String briefId,
  }) async {
    final Map<String, dynamic> body = await _send(
      'POST',
      _resolve(<String>['api', 'sessions', host]),
      what: 'Starting the Command session',
      payload: <String, dynamic>{
        'workspace': workspace,
        'engine': planEngine,
        'prompt': briefId,
      },
    );
    final CommandSession? session = CommandSession.fromJson(body);
    if (session == null) {
      throw const FormatException(
        'The control plane started a session but named no session.',
      );
    }
    return session;
  }

  @override
  Future<CommandBriefStatus> briefStatus(String briefId) async {
    final Uri url = _resolve(<String>['api', 'briefs', briefId]);
    final http.Response response = await _client
        .get(
          url,
          headers: <String, String>{
            'accept': 'application/json',
            if (bearerToken != null && bearerToken!.isNotEmpty)
              'Authorization': 'Bearer $bearerToken',
          },
        )
        .timeout(requestTimeout);

    // The one status code with its own meaning here: it will not come right by
    // waiting, so the caller is told to stop rather than to retry.
    if (response.statusCode == 404) {
      throw CommandBriefGoneException(briefId);
    }

    final String body = utf8.decode(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        describeProviderFailure('Reading the Command brief', response.statusCode, body),
      );
    }

    final CommandBriefStatus? status = CommandBriefStatus.fromJson(
      jsonDecode(body),
      briefId: briefId,
    );
    if (status == null) {
      throw const FormatException('The brief status is not a JSON object.');
    }
    return status;
  }

  /// The engine the brief is handed to. Planning, never execution: RFC-0008
  /// gives this app read access to a run and no writes, so what leaves here is
  /// a request to *think about* the capture.
  static const String planEngine = 'command-plan';

  /// Joins onto the configured base **path**, rather than replacing it.
  ///
  /// `Uri.resolve` would discard everything after the host, so an aggregator
  /// served under `https://fleet.example/command/` — a perfectly ordinary
  /// reverse-proxy mount — would be asked for `/api/hosts` at the root and
  /// answer the proxy's own 404. The base path is kept and the segments are
  /// appended to it.
  Uri _resolve(List<String> segments) {
    final List<String> base = baseUrl.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .toList();
    return baseUrl.replace(pathSegments: <String>[...base, ...segments]);
  }

  /// One write, with the same failure policy as the reads.
  Future<Map<String, dynamic>> _send(
    String method,
    Uri url, {
    required String what,
    required Map<String, dynamic> payload,
  }) async {
    final http.Request request = http.Request(method, url)
      ..headers.addAll(<String, String>{
        'content-type': 'application/json; charset=utf-8',
        'accept': 'application/json',
        if (bearerToken != null && bearerToken!.isNotEmpty)
          'Authorization': 'Bearer $bearerToken',
      })
      ..bodyBytes = utf8.encode(jsonEncode(payload));

    final http.Response response = await http.Response.fromStream(
      await _client.send(request).timeout(requestTimeout),
    );
    final String body = utf8.decode(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        describeProviderFailure(what, response.statusCode, body),
      );
    }
    final dynamic decoded = body.trim().isEmpty ? null : jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  /// The list at [key], or the body itself when the endpoint answers a bare
  /// array. Both shapes are in the wild and neither is worth failing over.
  Future<List<dynamic>> _getList(
    Uri url, {
    required String what,
    required String key,
  }) async {
    final http.Response response = await _client
        .get(
          url,
          headers: <String, String>{
            'accept': 'application/json',
            if (bearerToken != null && bearerToken!.isNotEmpty)
              'Authorization': 'Bearer $bearerToken',
          },
        )
        .timeout(requestTimeout);

    final String body = utf8.decode(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Bounded, on the same rule as every other provider call in this app: a
      // 4xx routinely quotes the request back, and the message reaches the Logs
      // tab and whatever the user copies out of it.
      throw HttpException(
        describeProviderFailure(what, response.statusCode, body),
      );
    }

    final dynamic decoded = jsonDecode(body);
    if (decoded is List<dynamic>) return decoded;
    if (decoded is Map<String, dynamic> && decoded[key] is List<dynamic>) {
      return decoded[key] as List<dynamic>;
    }
    throw FormatException('$what returned no $key list.');
  }
}
