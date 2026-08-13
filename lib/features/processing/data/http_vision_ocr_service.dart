import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/http/provider_failure.dart';

import '../../costs/domain/usage_parsing.dart';
import '../../costs/domain/usage_sink.dart';
import 'ocr_service.dart';

/// OCR through a vision-capable chat model on an OpenAI-compatible
/// `/v1/chat/completions` endpoint — the same protocol (and, in practice,
/// the same provider profile) the enrichment stage uses, which is why
/// OpenAI, Groq, Ollama and Anthropic's compatibility endpoint all work
/// without dedicated adapters.
class HttpVisionOcrService implements OcrService {
  HttpVisionOcrService({
    required this.endpoint,
    this.bearerToken,
    this.model,
    http.Client? client,
    this.usageSink = const NoopUsageSink(),
  }) : _client = client ?? http.Client();

  final Uri endpoint;
  final String? bearerToken;
  final String? model;
  final http.Client _client;

  /// Receives what this call consumed. Defaults to a no-op, so nothing in the
  /// pure-Dart suite needs a database.
  final UsageSink usageSink;

  /// Providers reject payloads around this size and base64 inflates the bytes
  /// by 4/3 — a clear failure beats a silent one, and there is no image
  /// library in the deps to downscale with.
  static const int maxImageBytes = 20 * 1024 * 1024;

  /// The drain loop is single-flight, so a hung request would stall every
  /// queued item behind it.
  static const Duration requestTimeout = Duration(minutes: 2);

  static const String _instruction =
      'Transcribe all legible text from this image, in natural reading order. '
      'Preserve line breaks. Output only the transcribed text — no commentary, '
      'no markdown, no code fences. If the image contains no text, reply with '
      'an empty message.';

  @override
  Future<String> extractText(File image) async {
    if (!await image.exists()) {
      throw FileSystemException('Image file is missing.', image.path);
    }
    final int length = await image.length();
    if (length > maxImageBytes) {
      throw FileSystemException(
        'Image is too large for OCR '
        '(${(length / (1024 * 1024)).toStringAsFixed(1)} MB, limit 20 MB).',
        image.path,
      );
    }

    final List<int> bytes = await image.readAsBytes();
    final String mime = sniffImageMime(bytes, image.path);
    final String dataUrl = 'data:$mime;base64,${base64Encode(bytes)}';

    final Map<String, dynamic> payload = <String, dynamic>{
      if (model != null && model!.isNotEmpty) 'model': model,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'image_url',
              'image_url': <String, String>{'url': dataUrl},
            },
            <String, dynamic>{'type': 'text', 'text': _instruction},
          ],
        },
      ],
    };

    final http.Response response = await _client
        .post(
          endpoint,
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
            if (bearerToken != null && bearerToken!.isNotEmpty)
              'Authorization': 'Bearer $bearerToken',
          },
          // Explicit UTF-8: package:http would otherwise encode a String
          // body as latin-1 and mangle the instruction's future edits.
          body: utf8.encode(jsonEncode(payload)),
        )
        .timeout(requestTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        describeProviderFailure(
          'OCR',
          response.statusCode,
          utf8.decode(response.bodyBytes),
        ),
      );
    }

    final String body = utf8.decode(response.bodyBytes);
    _recordUsage(body);
    return parseResponse(body);
  }

  /// Accounting must never cost a capture: a malformed usage block, or a sink
  /// that throws, is swallowed here rather than turned into a failed OCR.
  /// Same contract as `ClipboardSink`.
  void _recordUsage(String body) {
    try {
      final dynamic envelope = jsonDecode(body);
      if (envelope is! Map<String, dynamic>) return;
      usageSink.record(
        provider: endpoint.host,
        model: model ?? '',
        usage: parseUsage(envelope),
      );
    } catch (_) {
      // Deliberately silent.
    }
  }

  /// Extracts the assistant text from a chat-completions body. A body that is
  /// not shaped like one throws [FormatException] so the failure lands in the
  /// item's error string and the log.
  static String parseResponse(String body) {
    final dynamic decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('OCR response is not a JSON object.');
    }
    final dynamic choices = decoded['choices'];
    dynamic content;
    if (choices is List && choices.isNotEmpty) {
      final dynamic first = choices.first;
      if (first is Map<String, dynamic>) {
        final dynamic message = first['message'];
        if (message is Map<String, dynamic>) {
          content = message['content'];
        }
      }
    }
    if (content is! String) {
      throw const FormatException('OCR response contains no message content.');
    }
    return _stripFence(content.trim());
  }

  /// Vision models occasionally wrap plain-text output in a ``` fence even
  /// when told not to.
  static String _stripFence(String text) {
    if (!text.startsWith('```')) return text;
    final int firstBreak = text.indexOf('\n');
    if (firstBreak == -1) return text;
    final int lastFence = text.lastIndexOf('```');
    if (lastFence <= firstBreak) return text;
    return text.substring(firstBreak + 1, lastFence).trim();
  }

  /// Mime from magic bytes, because the stored extension can lie: the import
  /// path derives it from the picked filename and falls back to `.jpg` for
  /// unknown image types, and mic-era rows have no mime at all.
  static String sniffImageMime(List<int> bytes, String path) {
    if (bytes.length >= 12) {
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) return 'image/jpeg';
      if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E) {
        return 'image/png';
      }
      if (bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50) {
        return 'image/webp';
      }
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
        return 'image/gif';
      }
      // ISO BMFF: '....ftypheic' and friends.
      if (bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70) {
        return 'image/heic';
      }
    }
    final String lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.heic')) return 'image/heic';
    return 'image/jpeg';
  }
}
