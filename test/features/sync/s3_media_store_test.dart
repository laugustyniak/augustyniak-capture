import 'dart:async';
import 'dart:io';

import 'package:augustyniak_capture/features/sync/data/s3_media_store.dart';
import 'package:augustyniak_capture/features/sync/domain/media_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  group('S3MediaStore', () {
    const endpoint = 'https://s3.amazonaws.com';
    const bucket = 'my-bucket';
    const accessKeyId = 'access-key';
    const secretAccessKey = 'secret-key';
    const region = 'us-east-1';

    test('authorizes with SigV4', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response('', 200);
      });

      final store = S3MediaStore(
        endpoint: endpoint,
        bucket: bucket,
        accessKeyId: accessKeyId,
        secretAccessKey: secretAccessKey,
        region: region,
        client: mockClient,
      );

      await store.exists('test.txt');

      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.headers.containsKey('Authorization'), isTrue);
      expect(capturedRequest!.headers.containsKey('x-amz-date'), isTrue);
      expect(capturedRequest!.headers['Authorization'], contains('AWS4-HMAC-SHA256'));
      expect(capturedRequest!.headers['Authorization'], contains('Credential=$accessKeyId'));
      
      final date = capturedRequest!.headers['x-amz-date']!;
      final shortDate = date.substring(0, 8);
      expect(
        capturedRequest!.headers['Authorization'],
        contains('$shortDate/$region/s3/aws4_request'),
      );
    });

    test('exists returns true for 200', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 200);
      });
      final store = S3MediaStore(
        endpoint: endpoint, bucket: bucket, accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, region: region, client: mockClient,
      );
      expect(await store.exists('test.txt'), isTrue);
    });

    test('exists returns false for 404', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 404);
      });
      final store = S3MediaStore(
        endpoint: endpoint, bucket: bucket, accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, region: region, client: mockClient,
      );
      expect(await store.exists('test.txt'), isFalse);
    });

    test('exists throws MediaStoreUnreachableException on network error', () async {
      final mockClient = MockClient((request) async {
        throw const SocketException('Failed host lookup');
      });
      final store = S3MediaStore(
        endpoint: endpoint, bucket: bucket, accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, region: region, client: mockClient,
      );
      expect(() => store.exists('test.txt'), throwsA(isA<MediaStoreUnreachableException>()));
    });

    test('upload sends correct headers and body', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response('', 200);
      });
      final store = S3MediaStore(
        endpoint: endpoint, bucket: bucket, accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, region: region, client: mockClient,
      );

      final file = File(p.join(Directory.systemTemp.path, 'test_upload.txt'));
      await file.writeAsString('hello');
      final sha256Hash = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'; // hash of 'hello'

      await store.upload('test.txt', file, sha256: sha256Hash);

      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.method, 'PUT');
      expect(capturedRequest!.headers['x-amz-meta-sha256'], sha256Hash);
      expect(capturedRequest!.headers['if-none-match'], '*');
      expect(capturedRequest!.headers['x-amz-content-sha256'], sha256Hash);
      expect(capturedRequest!.bodyBytes, 'hello'.codeUnits);
    });

    test('upload throws MediaObjectExistsException on 412/409', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 412);
      });
      final store = S3MediaStore(
        endpoint: endpoint, bucket: bucket, accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, region: region, client: mockClient,
      );

      final file = File(p.join(Directory.systemTemp.path, 'test_upload2.txt'))..writeAsStringSync('a');
      expect(
        () => store.upload('test.txt', file, sha256: 'somehash'),
        throwsA(isA<MediaObjectExistsException>()),
      );
    });

    test('upload throws MediaStoreUnreachableException on network error', () async {
      final mockClient = MockClient((request) async {
        throw http.ClientException('Error');
      });
      final store = S3MediaStore(
        endpoint: endpoint, bucket: bucket, accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, region: region, client: mockClient,
      );

      final file = File(p.join(Directory.systemTemp.path, 'test_upload3.txt'))..writeAsStringSync('a');
      expect(
        () => store.upload('test.txt', file, sha256: 'somehash'),
        throwsA(isA<MediaStoreUnreachableException>()),
      );
    });

    test('download returns bytes', () async {
      final mockClient = MockClient((request) async {
        return http.Response('data', 200);
      });
      final store = S3MediaStore(
        endpoint: endpoint, bucket: bucket, accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, region: region, client: mockClient,
      );

      final bytes = await store.download('test.txt');
      expect(String.fromCharCodes(bytes), 'data');
    });

    test('download throws MediaStoreUnreachableException on timeout', () async {
      final mockClient = MockClient((request) async {
        throw TimeoutException('Timeout');
      });
      final store = S3MediaStore(
        endpoint: endpoint, bucket: bucket, accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, region: region, client: mockClient,
      );

      expect(() => store.download('test.txt'), throwsA(isA<MediaStoreUnreachableException>()));
    });
  });
}
