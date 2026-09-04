import 'dart:async';
import 'dart:io';

import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';

import 'r2_media_sync_service.dart';

class SignedR2ObjectStore implements R2ObjectStore {
  SignedR2ObjectStore({
    required String endpoint,
    required this.bucket,
    required String accessKeyId,
    required String secretAccessKey,
    this.timeout = const Duration(seconds: 30),
  }) : endpoint = Uri.parse(endpoint),
       _signer = AWSSigV4Signer(
         credentialsProvider: StaticCredentialsProvider(
           AWSCredentials(accessKeyId, secretAccessKey),
         ),
       );

  final Uri endpoint;
  final String bucket;
  final Duration timeout;
  final AWSSigV4Signer _signer;

  static final S3ServiceConfiguration _configuration = S3ServiceConfiguration();
  static final AWSCredentialScope _scope = AWSCredentialScope(
    region: 'auto',
    service: AWSService.s3,
  );

  Uri _uri([String? key]) {
    final String base = endpoint.toString().replaceFirst(RegExp(r'/+$'), '');
    final String bucketPath = Uri.encodeComponent(bucket);
    if (key == null) return Uri.parse('$base/$bucketPath');
    final String objectPath = key.split('/').map(Uri.encodeComponent).join('/');
    return Uri.parse('$base/$bucketPath/$objectPath');
  }

  Future<AWSBaseHttpResponse> _send(AWSBaseHttpRequest request) async {
    final AWSSignedRequest signed = await _signer.sign(
      request,
      credentialScope: _scope,
      serviceConfiguration: _configuration,
    );
    return signed.send().response.timeout(timeout);
  }

  @override
  Future<void> validate() async {
    final AWSBaseHttpResponse response = await _send(
      AWSHttpRequest.head(_uri()),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw R2StoreException(_failure('check the bucket', response.statusCode));
    }
  }

  @override
  Future<R2RemoteObject?> head(String key) async {
    final AWSBaseHttpResponse response = await _send(
      AWSHttpRequest.head(_uri(key)),
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw R2StoreException(
        _failure('inspect an object', response.statusCode),
      );
    }
    return R2RemoteObject(
      sha256: response.headers['x-amz-meta-sha256'],
      size: int.tryParse(response.headers['content-length'] ?? '') ?? 0,
    );
  }

  @override
  Future<void> upload({
    required String key,
    required File source,
    required String sha256,
  }) async {
    final AWSBaseHttpResponse response = await _send(
      AWSStreamedHttpRequest.put(
        _uri(key),
        body: source.openRead(),
        contentLength: await source.length(),
        headers: <String, String>{
          AWSHeaders.contentType: 'application/octet-stream',
          'if-none-match': '*',
          'x-amz-meta-sha256': sha256,
        },
      ),
    );
    if (response.statusCode == HttpStatus.preconditionFailed) {
      throw const R2ObjectAlreadyExistsException();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw R2StoreException(_failure('upload an object', response.statusCode));
    }
  }

  @override
  Future<void> download({
    required String key,
    required File destination,
  }) async {
    final AWSBaseHttpResponse response = await _send(
      AWSHttpRequest.get(_uri(key)),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw R2StoreException(
        _failure('download an object', response.statusCode),
      );
    }
    final IOSink sink = destination.openWrite();
    Object? bodyError;
    StackTrace? bodyStackTrace;
    try {
      await sink.addStream(response.body.timeout(timeout));
    } catch (error, stackTrace) {
      bodyError = error;
      bodyStackTrace = stackTrace;
    }
    try {
      await sink.close();
    } catch (_) {
      if (bodyError == null) rethrow;
    }
    if (bodyError != null) {
      Error.throwWithStackTrace(bodyError, bodyStackTrace!);
    }
  }

  static String _failure(String action, int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      return 'R2 rejected the access key while trying to $action (HTTP $statusCode).';
    }
    if (statusCode == 404) {
      return 'R2 bucket was not found (HTTP 404). Check the endpoint and bucket name.';
    }
    if (statusCode == 408 || statusCode == 429) {
      return 'R2 temporarily refused the request (HTTP $statusCode). Try again.';
    }
    if (statusCode >= 500) {
      return 'R2 is temporarily unavailable (HTTP $statusCode). Try again.';
    }
    return 'R2 could not $action (HTTP $statusCode).';
  }
}
