import 'dart:io';
import 'dart:async';

import 'package:augustyniak_capture/core/sync/signed_r2_object_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('signs bucket and object requests and streams bytes', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Directory directory = await Directory.systemTemp.createTemp(
      'signed-r2-store-',
    );
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });

    final List<String> requests = <String>[];
    final List<int> uploaded = <int>[];
    final Future<void> serve = () async {
      await for (final HttpRequest request in server) {
        requests.add('${request.method} ${request.uri.path}');
        expect(
          request.headers.value('authorization'),
          contains('/auto/s3/aws4_request'),
        );
        switch ((request.method, request.uri.path)) {
          case ('HEAD', '/captures'):
            request.response.statusCode = HttpStatus.ok;
          case ('HEAD', '/captures/captures/id/voice%20clip.m4a'):
            request.response.statusCode = HttpStatus.ok;
            request.response.headers
              ..set('x-amz-meta-sha256', 'abc123')
              ..set(HttpHeaders.contentLengthHeader, '3');
          case ('PUT', '/captures/captures/id/voice%20clip.m4a'):
            expect(request.headers.value('if-none-match'), '*');
            uploaded.addAll(
              await request.fold<List<int>>(
                <int>[],
                (List<int> bytes, List<int> chunk) => bytes..addAll(chunk),
              ),
            );
            request.response.statusCode = HttpStatus.ok;
          case ('GET', '/captures/captures/id/voice%20clip.m4a'):
            request.response
              ..statusCode = HttpStatus.ok
              ..add(<int>[4, 5, 6]);
          default:
            request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
        if (requests.length == 4) break;
      }
    }();

    final SignedR2ObjectStore store = SignedR2ObjectStore(
      endpoint: 'http://${server.address.address}:${server.port}',
      bucket: 'captures',
      accessKeyId: 'access-key',
      secretAccessKey: 'secret-key',
    );
    final File source = File('${directory.path}/source.bin');
    final File destination = File('${directory.path}/destination.bin');
    await source.writeAsBytes(<int>[1, 2, 3]);

    await store.validate();
    final remote = await store.head('captures/id/voice clip.m4a');
    await store.upload(
      key: 'captures/id/voice clip.m4a',
      source: source,
      sha256: 'abc123',
    );
    await store.download(
      key: 'captures/id/voice clip.m4a',
      destination: destination,
    );
    await serve;

    expect(remote?.sha256, 'abc123');
    expect(remote?.size, 3);
    expect(uploaded, <int>[1, 2, 3]);
    expect(await destination.readAsBytes(), <int>[4, 5, 6]);
    expect(requests, <String>[
      'HEAD /captures',
      'HEAD /captures/captures/id/voice%20clip.m4a',
      'PUT /captures/captures/id/voice%20clip.m4a',
      'GET /captures/captures/id/voice%20clip.m4a',
    ]);
  });

  test('times out when a download body stops mid-stream', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Directory directory = await Directory.systemTemp.createTemp(
      'signed-r2-timeout-',
    );
    final Completer<void> releaseResponse = Completer<void>();
    addTearDown(() async {
      if (!releaseResponse.isCompleted) releaseResponse.complete();
      await server.close(force: true);
      await directory.delete(recursive: true);
    });

    final Future<void> serve = () async {
      final HttpRequest request = await server.first;
      request.response
        ..statusCode = HttpStatus.ok
        ..add(<int>[1]);
      await request.response.flush();
      await releaseResponse.future;
      await request.response.close();
    }();
    final SignedR2ObjectStore store = SignedR2ObjectStore(
      endpoint: 'http://${server.address.address}:${server.port}',
      bucket: 'captures',
      accessKeyId: 'access-key',
      secretAccessKey: 'secret-key',
      timeout: const Duration(milliseconds: 50),
    );

    await expectLater(
      store.download(
        key: 'captures/id/file.m4a',
        destination: File('${directory.path}/destination.bin'),
      ),
      throwsA(isA<TimeoutException>()),
    );
    releaseResponse.complete();
    await serve;
  });
}
