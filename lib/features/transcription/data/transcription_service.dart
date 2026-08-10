import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../costs/domain/usage_parsing.dart';
import '../../costs/domain/usage_sink.dart';

abstract interface class TranscriptionService {
  Future<String> transcribe(File audioFile);
}

class DisabledTranscriptionService implements TranscriptionService {
  const DisabledTranscriptionService();

  @override
  Future<String> transcribe(File audioFile) async {
    throw const TranscriptionNotConfiguredException();
  }
}

class HttpWhisperTranscriptionService implements TranscriptionService {
  HttpWhisperTranscriptionService({
    required this.endpoint,
    this.bearerToken,
    this.model,
    this.language,
    http.Client? client,
    this.usageSink = const NoopUsageSink(),
  }) : _client = client ?? http.Client();

  final Uri endpoint;
  final String? bearerToken;

  /// Model form field. Required by OpenAI (`whisper-1`, `gpt-4o-transcribe`,
  /// `gpt-4o-mini-transcribe`); ignored by servers that don't expect it.
  final String? model;

  /// Optional ISO-639-1 hint (e.g. `pl`). Improves accuracy on known-language
  /// audio and skips language auto-detection.
  final String? language;
  final http.Client _client;

  /// Receives what this call consumed. Defaults to a no-op, so nothing in the
  /// pure-Dart suite needs a database.
  final UsageSink usageSink;

  @override
  Future<String> transcribe(File audioFile) async {
    final http.MultipartRequest request = http.MultipartRequest(
      'POST',
      endpoint,
    )..files.add(await http.MultipartFile.fromPath('file', audioFile.path));

    if (model != null && model!.isNotEmpty) {
      request.fields['model'] = model!;
    }
    if (language != null && language!.isNotEmpty) {
      request.fields['language'] = language!;
    }

    if (bearerToken != null && bearerToken!.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $bearerToken';
    }

    final http.StreamedResponse response = await _client.send(request);
    final String body = await response.stream.bytesToString();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Transcription failed (${response.statusCode}): $body',
      );
    }

    _recordUsage(body);

    final dynamic decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final dynamic text = decoded['text'] ?? decoded['transcript'];
      if (text is String) {
        if (text.trim().isNotEmpty) return text.trim();

        // A present-but-empty `text` is the provider answering correctly that
        // there was nothing to transcribe — OpenAI returns
        // `{"text":"","languages":[],"usage":{…}}` with HTTP 200 for silence.
        // Reporting that as a malformed response sent the reader of the Logs
        // tab to the API contract when the only thing wrong was that nobody
        // spoke. Still a failure, because a capture with no words is not a
        // finished transcription and should stay retryable — but one whose
        // message names the actual cause.
        throw const FormatException(
          'The provider transcribed no speech in this recording.',
        );
      }
    }

    throw const FormatException(
      'Response does not contain text or transcript.',
    );
  }

  /// Accounting must never cost a capture: a malformed usage block, or a sink
  /// that throws, is swallowed here rather than turned into a failed
  /// transcription. Same contract as `ClipboardSink`.
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
}

class TranscriptionNotConfiguredException implements Exception {
  const TranscriptionNotConfiguredException();

  @override
  String toString() => 'Transcription endpoint is not configured.';
}
