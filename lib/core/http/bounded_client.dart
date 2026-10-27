import 'dart:async';

import 'package:http/http.dart' as http;

/// Thrown by [BoundedClient] when a response body crosses its ceiling. The
/// bytes read so far are discarded; nothing above the ceiling is buffered.
class ResponseTooLargeException implements Exception {
  const ResponseTooLargeException(this.maxBytes);

  final int maxBytes;

  @override
  String toString() =>
      'Response body exceeded the ${describeBytes(maxBytes)} ceiling.';
}

/// A client whose every response body is capped at [maxBytes]. `post`, `get`
/// and `send` all go through [send], so one wrap bounds every read a provider
/// client makes, success and error bodies alike.
class BoundedClient extends http.BaseClient {
  BoundedClient(this._inner, {required this.maxBytes});

  final http.Client _inner;
  final int maxBytes;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final http.StreamedResponse response = await _inner.send(request);
    // Cheap early refusal. Content-Length can lie, so the stream is counted
    // as well.
    final int? declared = response.contentLength;
    if (declared != null && declared > maxBytes) {
      unawaited(response.stream.listen(null).cancel());
      throw ResponseTooLargeException(maxBytes);
    }
    return http.StreamedResponse(
      boundedBytes(response.stream, maxBytes: maxBytes),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

/// Forwards [source] until the running total would cross [maxBytes], then
/// errors with [ResponseTooLargeException] and stops pulling.
Stream<List<int>> boundedBytes(
  Stream<List<int>> source, {
  required int maxBytes,
}) async* {
  int received = 0;
  await for (final List<int> chunk in source) {
    received += chunk.length;
    if (received > maxBytes) throw ResponseTooLargeException(maxBytes);
    yield chunk;
  }
}

/// "4 MiB" for a whole number of MiB, the raw byte count otherwise.
String describeBytes(int bytes) =>
    bytes > 0 && bytes % (1 << 20) == 0 ? '${bytes >> 20} MiB' : '$bytes bytes';
