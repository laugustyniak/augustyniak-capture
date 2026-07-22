import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Uri endpoint;
  final String? bearerToken;
  final http.Client _client;

  @override
  Future<String> transcribe(File audioFile) async {
    final http.MultipartRequest request = http.MultipartRequest('POST', endpoint)
      ..files.add(await http.MultipartFile.fromPath('file', audioFile.path));

    if (bearerToken != null && bearerToken!.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $bearerToken';
    }

    final http.StreamedResponse response = await _client.send(request);
    final String body = await response.stream.bytesToString();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Transcription failed (${response.statusCode}): $body');
    }

    final dynamic decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final dynamic text = decoded['text'] ?? decoded['transcript'];
      if (text is String && text.trim().isNotEmpty) {
        return text.trim();
      }
    }

    throw const FormatException('Response does not contain text or transcript.');
  }
}

class TranscriptionNotConfiguredException implements Exception {
  const TranscriptionNotConfiguredException();

  @override
  String toString() => 'Transcription endpoint is not configured.';
}
