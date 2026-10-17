import 'dart:async';
import 'dart:convert';

import 'package:augustyniak_capture/core/http/bounded_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A client with no declared length, so only the streamed count can refuse.
MockClient _undeclared(String body, int status) => MockClient.streaming(
  (http.BaseRequest r, http.ByteStream s) async =>
      http.StreamedResponse(Stream<List<int>>.value(utf8.encode(body)), status),
);

/// Serves [chunks] and counts how many the consumer actually pulled.
class _ChunkedClient extends http.BaseClient {
  _ChunkedClient(this.chunks, {this.contentLength});
  final List<List<int>> chunks;
  final int? contentLength;
  int pulled = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(chunks).map((List<int> c) {
        pulled++;
        return c;
      }),
      200,
      contentLength: contentLength,
    );
  }
}

void main() {
  final Uri url = Uri.parse('http://localhost/x');

  test('a body under the ceiling passes through unchanged', () async {
    final BoundedClient client = BoundedClient(
      MockClient(
        (http.Request r) async =>
            http.Response('hello', 201, headers: <String, String>{'x-a': 'b'}),
      ),
      maxBytes: 5,
    );
    final http.Response response = await client.post(url, body: 'q');
    expect(response.statusCode, 201);
    expect(response.headers['x-a'], 'b');
    expect(response.body, 'hello');
  });

  test('a body over the ceiling throws without echoing the body', () async {
    final BoundedClient client = BoundedClient(
      _undeclared('secret-body', 200),
      maxBytes: 4,
    );
    await expectLater(
      client.post(url),
      throwsA(
        isA<ResponseTooLargeException>()
            .having((ResponseTooLargeException e) => e.maxBytes, 'maxBytes', 4)
            .having(
              (ResponseTooLargeException e) => e.toString(),
              'message',
              allOf(contains('4 bytes'), isNot(contains('secret'))),
            ),
      ),
    );
  });

  test('send stops pulling once the ceiling is crossed', () async {
    final _ChunkedClient inner = _ChunkedClient(
      List<List<int>>.generate(100, (int _) => utf8.encode('abcd')),
    );
    final BoundedClient client = BoundedClient(inner, maxBytes: 10);
    final http.StreamedResponse response = await client.send(
      http.Request('GET', url),
    );
    await expectLater(
      response.stream.drain<void>(),
      throwsA(isA<ResponseTooLargeException>()),
    );
    expect(inner.pulled, lessThan(100));
    expect(inner.pulled, 3);
  });

  test(
    'a Content-Length above the ceiling is refused before reading',
    () async {
      final _ChunkedClient inner = _ChunkedClient(<List<int>>[
        utf8.encode('abcd'),
      ], contentLength: 1000);
      final BoundedClient client = BoundedClient(inner, maxBytes: 10);
      await expectLater(
        client.send(http.Request('GET', url)),
        throwsA(isA<ResponseTooLargeException>()),
      );
      expect(inner.pulled, 0);
    },
  );

  test('an error body over the ceiling is bounded too', () async {
    final BoundedClient client = BoundedClient(
      _undeclared('x' * 50, 500),
      maxBytes: 10,
    );
    await expectLater(
      client.get(url),
      throwsA(isA<ResponseTooLargeException>()),
    );
  });

  test('a body exactly at the ceiling is accepted', () async {
    final BoundedClient client = BoundedClient(
      MockClient((http.Request r) async => http.Response('x' * 10, 200)),
      maxBytes: 10,
    );
    expect((await client.get(url)).body, 'x' * 10);
  });

  test('describeBytes names whole MiB and falls back to bytes', () {
    expect(describeBytes(4 << 20), '4 MiB');
    expect(describeBytes(10), '10 bytes');
  });
}
