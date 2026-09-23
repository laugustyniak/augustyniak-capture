import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/sync/data/supabase_media_store.dart';
import 'package:augustyniak_capture/features/sync/domain/media_sync.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

/// `SupabaseMediaStore` against a real, locally running Supabase stack
/// (`supabase start`, migrations applied). Skipped unless the same three env
/// vars `local_stack_e2e_test.dart` reads are set:
///
///   SUPABASE_E2E_URL              e.g. http://127.0.0.1:54321
///   SUPABASE_E2E_ANON_KEY         `supabase status -o json` .ANON_KEY
///   SUPABASE_E2E_SERVICE_ROLE_KEY `supabase status -o json` .SERVICE_ROLE_KEY
///
/// It checks what the in-memory fake can only assume: the owner prefix the
/// bucket policies accept, the duplicate-upload mapping, and that another
/// user can neither see nor fetch the object.
void main() {
  final String? url = Platform.environment['SUPABASE_E2E_URL'];
  final String? anonKey = Platform.environment['SUPABASE_E2E_ANON_KEY'];
  final String? serviceRoleKey =
      Platform.environment['SUPABASE_E2E_SERVICE_ROLE_KEY'];
  final bool ready = url != null && anonKey != null && serviceRoleKey != null;

  test(
    'upload, duplicate, download and isolation through the real bucket',
    () async {
      final String suffix = DateTime.now().microsecondsSinceEpoch.toString();
      final SupabaseClient a = SupabaseClient(url!, anonKey!);
      final SupabaseClient b = SupabaseClient(url, anonKey);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      for (final (SupabaseClient client, String who)
          in <(SupabaseClient, String)>[(a, 'a'), (b, 'b')]) {
        final String email = 'media-$who-$suffix@example.com';
        final String pass = 'e2e-$who-$suffix';
        await _createUser(url, serviceRoleKey!, email, pass);
        await client.auth.signInWithPassword(email: email, password: pass);
      }

      final Directory dir = await Directory.systemTemp.createTemp('media-e2e');
      addTearDown(() => dir.delete(recursive: true));
      final List<int> audio = utf8.encode('audio-$suffix');
      final File source = File(p.join(dir.path, 'r1.m4a'))
        ..writeAsBytesSync(audio);
      final String hash = sha256.convert(audio).toString();
      final String key = 'captures/r-$suffix/r1.m4a';

      final SupabaseMediaStore storeA = SupabaseMediaStore(
        a,
        ownerId: a.auth.currentUser!.id,
      );
      final SupabaseMediaStore storeB = SupabaseMediaStore(
        b,
        ownerId: b.auth.currentUser!.id,
      );
      // B writing under A's prefix — what a hostile client would try.
      final SupabaseMediaStore storeBAsA = SupabaseMediaStore(
        b,
        ownerId: a.auth.currentUser!.id,
      );

      expect(await storeA.exists(key), isFalse);
      await storeA.upload(key, source, sha256: hash);
      expect(await storeA.exists(key), isTrue);
      await expectLater(
        storeA.upload(key, source, sha256: hash),
        throwsA(isA<MediaObjectExistsException>()),
      );
      expect(await storeA.download(key), audio);

      expect(await storeB.exists(key), isFalse);
      expect(await storeBAsA.exists(key), isFalse);
      await expectLater(
        storeBAsA.download(key),
        throwsA(isA<StorageException>()),
      );
      await expectLater(
        storeBAsA.upload('captures/r-$suffix/x.m4a', source, sha256: hash),
        throwsA(isA<StorageException>()),
      );
    },
    skip: ready
        ? false
        : 'set SUPABASE_E2E_URL, SUPABASE_E2E_ANON_KEY, SUPABASE_E2E_SERVICE_ROLE_KEY',
  );
}

Future<void> _createUser(
  String url,
  String serviceRoleKey,
  String email,
  String password,
) async {
  final http.Response response = await http.post(
    Uri.parse('$url/auth/v1/admin/users'),
    headers: <String, String>{
      'apikey': serviceRoleKey,
      'Authorization': 'Bearer $serviceRoleKey',
      'Content-Type': 'application/json',
    },
    body: jsonEncode(<String, Object?>{
      'email': email,
      'password': password,
      'email_confirm': true,
    }),
  );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError(
      'admin user creation for $email failed: ${response.statusCode}',
    );
  }
}
