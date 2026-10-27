import 'dart:io';

import 'package:augustyniak_capture/features/sync/data/supabase_media_store.dart';
import 'package:augustyniak_capture/features/sync/domain/media_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// `storage_client` wraps a lost connection in a `StorageException`, so the
/// store has to translate it for the pass to stop instead of failing one
/// job at a time. A closed loopback port gives a real refused connection
/// without leaving the machine.
void main() {
  test(
    'an unreachable server surfaces as MediaStoreUnreachableException',
    () async {
      final ServerSocket probe = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int port = probe.port;
      await probe.close();
      final SupabaseClient client = SupabaseClient(
        'http://127.0.0.1:$port',
        'publishable-key',
      );
      addTearDown(client.dispose);
      final SupabaseMediaStore store = SupabaseMediaStore(
        client,
        ownerId: 'u1',
      );

      await expectLater(
        store.exists('captures/r1/r1.m4a'),
        throwsA(isA<MediaStoreUnreachableException>()),
      );
      await expectLater(
        store.download('captures/r1/r1.m4a', maxBytes: 1 << 20).toList(),
        throwsA(isA<MediaStoreUnreachableException>()),
      );
    },
  );

  group('download streams from the server', () {
    late HttpServer server;
    late SupabaseMediaStore store;
    final List<String> paths = <String>[];

    setUp(() async {
      paths.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final SupabaseClient client = SupabaseClient(
        'http://127.0.0.1:${server.port}',
        'test-anon-key',
      );
      addTearDown(client.dispose);
      addTearDown(() => server.close(force: true));
      store = SupabaseMediaStore(client, ownerId: 'u1');
    });

    test('a body past the ceiling fails with MediaObjectTooLargeException, '
        'not a transport error', () async {
      // Whether the client stops reading early is not observable through
      // the socket (the kernel buffers all 64 bytes), so only the exception
      // is asserted. Removing the ceiling makes toList() succeed.
      server.listen((HttpRequest request) async {
        request.response.statusCode = 200;
        for (int i = 0; i < 8; i++) {
          request.response.add(List<int>.filled(8, i));
          await request.response.flush();
        }
        await request.response.close();
      });

      await expectLater(
        store.download('captures/r1/r1.m4a', maxBytes: 8).toList(),
        throwsA(isA<MediaObjectTooLargeException>()),
      );
    });

    test('a 404 surfaces as StorageException, not unreachable', () async {
      server.listen((HttpRequest request) async {
        request.response
          ..statusCode = 404
          ..headers.contentType = ContentType.json
          ..write('{"statusCode":"404","error":"not_found","message":"gone"}');
        await request.response.close();
      });

      await expectLater(
        store.download('captures/r1/r1.m4a', maxBytes: 1 << 20).toList(),
        throwsA(isA<StorageException>()),
      );
    });

    test('a body at the ceiling yields exactly its bytes', () async {
      final List<int> body = List<int>.generate(16, (int i) => i);
      server.listen((HttpRequest request) async {
        paths.add(request.uri.path);
        request.response.statusCode = 200;
        request.response.add(body);
        await request.response.close();
      });

      final List<int> got = <int>[
        for (final List<int> chunk
            in await store
                .download('captures/r1/r1.m4a', maxBytes: 16)
                .toList())
          ...chunk,
      ];

      expect(got, body);
      expect(paths, <String>[
        '/storage/v1/object/captures/u1/captures/r1/r1.m4a',
      ]);
    });
  });
}
