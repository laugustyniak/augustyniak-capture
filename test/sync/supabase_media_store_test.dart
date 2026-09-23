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
        store.download('captures/r1/r1.m4a'),
        throwsA(isA<MediaStoreUnreachableException>()),
      );
    },
  );
}
