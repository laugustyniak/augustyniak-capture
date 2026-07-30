import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../recordings/domain/capture_category.dart';
import '../domain/enrichment_prompt.dart';
import '../domain/enrichment_result.dart';
import '../domain/enrichment_service.dart';

/// OpenAI-compatible `/v1/chat/completions` client.
///
/// Deliberately the same shape as `HttpWhisperTranscriptionService`: one POST,
/// an optional bearer token, a configurable model, and a defensive parse. Works
/// against OpenAI, Groq and a local Ollama without a code change, because all
/// three speak this body.
class HttpChatEnrichmentService implements EnrichmentService {
  HttpChatEnrichmentService({
    required this.endpoint,
    this.bearerToken,
    this.model,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Uri endpoint;
  final String? bearerToken;

  /// Required by OpenAI and Groq, ignored by servers that don't read it.
  final String? model;
  final http.Client _client;

  /// More than five would be noise on a card, and the prompt already asks for
  /// three to five.
  static const int _maxTags = 5;

  @override
  Future<EnrichmentResult> enrich(String text) async {
    final Map<String, dynamic> payload = <String, dynamic>{
      if (model != null && model!.isNotEmpty) 'model': model,
      'response_format': <String, String>{'type': 'json_object'},
      'messages': <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content': buildEnrichmentSystemPrompt(),
        },
        <String, String>{
          'role': 'user',
          'content': truncateForEnrichment(text),
        },
      ],
    };

    final http.Response response = await _client.post(
      endpoint,
      headers: <String, String>{
        'content-type': 'application/json; charset=utf-8',
        if (bearerToken != null && bearerToken!.isNotEmpty)
          'Authorization': 'Bearer $bearerToken',
      },
      // Encoded to UTF-8 explicitly: `http` defaults a string body without a
      // charset to latin-1, which would mangle every Polish transcript on the
      // way out.
      body: utf8.encode(jsonEncode(payload)),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Enrichment failed (${response.statusCode}): ${response.body}',
      );
    }

    return parseResponse(utf8.decode(response.bodyBytes));
  }

  /// Exposed for tests, and kept separate from the transport so the parsing
  /// rules can be read in one piece.
  ///
  /// The degrade/throw split is deliberate: a body that *is* a JSON object
  /// degrades field by field, because a usable category with a blank title is
  /// still worth storing. A body that is not JSON at all throws, because there
  /// is nothing to degrade to and the caller should log it.
  static EnrichmentResult parseResponse(String body) {
    final dynamic envelope = jsonDecode(body);
    if (envelope is! Map<String, dynamic>) {
      throw const FormatException('Response is not a JSON object.');
    }

    final dynamic choices = envelope['choices'];
    final dynamic first =
        choices is List<dynamic> && choices.isNotEmpty ? choices.first : null;
    final dynamic message =
        first is Map<String, dynamic> ? first['message'] : null;
    final dynamic content =
        message is Map<String, dynamic> ? message['content'] : null;
    if (content is! String) {
      throw const FormatException('Response contains no message content.');
    }

    final dynamic decoded = _decodeContent(content);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Message content is not a JSON object.');
    }

    return EnrichmentResult(
      title: _cleanText(decoded['title']),
      category: CaptureCategory.fromName(
        decoded['category'] is String ? decoded['category'] as String : null,
      ),
      summary: _cleanText(decoded['summary']),
      tags: _cleanTags(decoded['tags']),
    );
  }

  /// `jsonDecode` throws a `FormatException` on garbage, which is exactly the
  /// signal the caller wants — but only after the fence is stripped, or every
  /// fenced reply would read as garbage.
  static dynamic _decodeContent(String content) =>
      jsonDecode(_stripFence(content));

  /// Models with a JSON mode still wrap their output in a fence often enough
  /// that not handling it would be the most common failure in the log.
  static String _stripFence(String raw) {
    final String trimmed = raw.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final int firstBreak = trimmed.indexOf('\n');
    if (firstBreak < 0) return trimmed;
    final String withoutOpen = trimmed.substring(firstBreak + 1);
    final int closing = withoutOpen.lastIndexOf('```');
    return (closing < 0 ? withoutOpen : withoutOpen.substring(0, closing))
        .trim();
  }

  static String? _cleanText(dynamic value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static List<String> _cleanTags(dynamic value) {
    if (value is! List<dynamic>) return const <String>[];
    final List<String> tags = <String>[];
    for (final dynamic item in value) {
      if (item is! String) continue;
      final String tag = item.trim().toLowerCase().replaceAll('#', '');
      if (tag.isEmpty || tags.contains(tag)) continue;
      tags.add(tag);
      if (tags.length == _maxTags) break;
    }
    return tags;
  }
}
