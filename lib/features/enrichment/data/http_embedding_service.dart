import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/http/provider_failure.dart';
import '../../costs/domain/usage_parsing.dart';
import '../../costs/domain/usage_sink.dart';
import '../domain/embedding_service.dart';

/// OpenAI-compatible `/v1/embeddings` client (#272). Speaks the body OpenAI,
/// Ollama and LM Studio all accept: `{model, input}` in, `data[0].embedding`
/// out.
class HttpEmbeddingService implements EmbeddingService {
  HttpEmbeddingService({
    required this.endpoint,
    required this.model,
    this.bearerToken,
    http.Client? client,
    this.usageSink = const NoopUsageSink(),
  }) : _client = client ?? http.Client();

  final Uri endpoint;
  @override
  final String model;
  final String? bearerToken;
  final http.Client _client;
  final UsageSink usageSink;

  @override
  Future<List<double>> embed(String text) async {
    final http.Response response = await _client
        .post(
          endpoint,
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
            if (bearerToken != null && bearerToken!.isNotEmpty)
              'Authorization': 'Bearer $bearerToken',
          },
          body: utf8.encode(
            jsonEncode(<String, dynamic>{'model': model, 'input': text}),
          ),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        describeProviderFailure(
          'Embedding',
          response.statusCode,
          response.body,
        ),
      );
    }
    final String body = utf8.decode(response.bodyBytes);
    final dynamic envelope = jsonDecode(body);
    if (envelope is! Map<String, dynamic>) {
      throw const FormatException('Embedding response is not a JSON object.');
    }
    _recordUsage(envelope);
    return parseVector(envelope);
  }

  /// `data[0].embedding` as doubles. Throws on anything else — an empty list,
  /// a non-number, a NaN — because a malformed vector stored once would be
  /// compared against every capture after it.
  static List<double> parseVector(Map<String, dynamic> envelope) {
    final dynamic data = envelope['data'];
    final dynamic first = data is List && data.isNotEmpty ? data.first : null;
    final dynamic raw = first is Map ? first['embedding'] : null;
    if (raw is! List || raw.isEmpty) {
      throw const FormatException('Embedding response holds no vector.');
    }
    final List<double> vector = <double>[];
    for (final dynamic each in raw) {
      if (each is! num || !each.isFinite) {
        throw const FormatException('Embedding vector holds a non-number.');
      }
      vector.add(each.toDouble());
    }
    return vector;
  }

  /// Best-effort, like every other service's accounting.
  void _recordUsage(Map<String, dynamic> envelope) {
    try {
      usageSink.record(
        provider: endpoint.host,
        model: model,
        usage: parseUsage(envelope),
      );
    } catch (_) {
      // Deliberately silent.
    }
  }
}
