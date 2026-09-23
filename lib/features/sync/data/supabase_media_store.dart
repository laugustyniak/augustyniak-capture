import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/media_sync.dart';

/// The private `captures` bucket. Every key is prefixed with the signed-in
/// user's id, because that first folder is what the bucket's policies compare
/// against `auth.uid()` — a key outside it is refused by the server, not here.
class SupabaseMediaStore implements MediaObjectStore {
  SupabaseMediaStore(this._client, {required String ownerId})
    : _ownerId = ownerId;

  static const String bucket = 'captures';

  final SupabaseClient _client;
  final String _ownerId;

  StorageFileApi get _bucket => _client.storage.from(bucket);
  String _path(String key) => '$_ownerId/$key';

  /// A lost connection reaches this store in two shapes: raw, from a plain
  /// request (`package:http`'s `ClientException`, or a `SocketException`),
  /// or folded by `storage_client` into a `StorageException` whose
  /// `statusCode` is the original error's type name (file uploads).
  static const Set<String> _transportFailures = <String>{
    'ClientException',
    'SocketException',
    'TimeoutException',
    'HandshakeException',
  };

  Future<T> _reach<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on StorageException catch (error) {
      if (_transportFailures.contains(error.statusCode)) {
        throw const MediaStoreUnreachableException();
      }
      rethrow;
    } on http.ClientException {
      throw const MediaStoreUnreachableException();
    } on SocketException {
      throw const MediaStoreUnreachableException();
    }
  }

  @override
  Future<bool> exists(String key) => _reach(() => _bucket.exists(_path(key)));

  @override
  Future<void> upload(String key, File source, {required String sha256}) =>
      _reach(() async {
        try {
          await _bucket.upload(
            _path(key),
            source,
            fileOptions: FileOptions(
              metadata: <String, dynamic>{'sha256': sha256},
            ),
          );
        } on StorageException catch (error) {
          // Storage answers a duplicate key with 409 in the body and 400 on the
          // wire, depending on the server version.
          if (error.statusCode == '409' || error.error == 'Duplicate') {
            throw const MediaObjectExistsException();
          }
          rethrow;
        }
      });

  @override
  Future<List<int>> download(String key) =>
      _reach(() => _bucket.download(_path(key)));
}
