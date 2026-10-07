import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../domain/media_sync.dart';

class S3MediaStore implements MediaObjectStore {
  S3MediaStore({
    required dynamic endpoint,
    required this.bucket,
    required this.accessKeyId,
    required this.secretAccessKey,
    this.region = 'auto',
    this.prefix,
    http.Client? client,
  })  : _endpoint = endpoint is Uri ? endpoint : Uri.parse(endpoint.toString()),
        _client = client ?? http.Client();

  final Uri _endpoint;
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;
  final String region;
  final String? prefix;
  final http.Client _client;

  static const String _emptyHash =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  @override
  Future<bool> exists(String key) async {
    return _mapErrors(() async {
      final request = _buildRequest('HEAD', key, _emptyHash);
      final response = await _client.send(request);
      if (response.statusCode == 200) return true;
      if (response.statusCode == 404) return false;
      throw Exception('Unexpected status code: ${response.statusCode}');
    });
  }

  @override
  Future<void> upload(String key, File source, {required String sha256}) async {
    return _mapErrors(() async {
      final request = _buildRequest('PUT', key, sha256);
      request.headers['x-amz-meta-sha256'] = sha256;
      request.headers['if-none-match'] = '*';
      
      final length = await source.length();
      request.headers['content-length'] = length.toString();
      
      final bytes = await source.readAsBytes();
      request.bodyBytes = bytes;

      _sign(request, sha256);

      final response = await _client.send(request);
      if (response.statusCode == 412 || response.statusCode == 409) {
        throw const MediaObjectExistsException();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Unexpected status code: ${response.statusCode}');
      }
    });
  }

  @override
  Future<List<int>> download(String key) async {
    return _mapErrors(() async {
      final request = _buildRequest('GET', key, _emptyHash);
      final response = await _client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Unexpected status code: ${response.statusCode}');
      }
      return await response.stream.toBytes();
    });
  }

  Future<T> _mapErrors<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on SocketException {
      throw const MediaStoreUnreachableException();
    } on http.ClientException {
      throw const MediaStoreUnreachableException();
    } on TimeoutException {
      throw const MediaStoreUnreachableException();
    }
  }

  http.Request _buildRequest(String method, String key, String payloadHash) {
    final fullKey = prefix != null ? '$prefix$key' : key;
    // Assume path style if the host doesn't include the bucket name?
    // Wait, let's just use path-style: endpoint.resolve('/$bucket/$fullKey') 
    // Wait, what if the endpoint already has the bucket? The task says:
    // endpoint (e.g. 'https://s3.amazonaws.com' or 'https://<account>.r2.cloudflarestorage.com'), bucket (String)
    // S3 path-style URL is standard when given an endpoint and bucket.
    // Path: /bucket/key. Let's use that. Wait, but many S3 implementations require path-style or virtual-host style. 
    // Since we only get `endpoint` and `bucket`, we probably want to use `endpoint.resolve('/$bucket/$fullKey')` for path style, or `https://$bucket.s3.amazonaws.com`.
    // Actually, SigV4 requires signing the path exactly as is.
    // Let's use virtual host style if the host ends with s3.amazonaws.com? No, path style is simpler and works universally except for AWS S3 with recent buckets... wait, AWS deprecated path style for S3 in 2020.
    // Let's use virtual host style if possible, or path-style? 
    // Wait, the prompt says nothing about path-style vs virtual host style. Let's just do `Uri.parse('$endpoint/$bucket/$fullKey')` as it's safe for path-style, and typically used in these custom endpoints.
    // Let's use `$_endpoint/$bucket/$fullKey`. 
    final uri = Uri.parse('${_endpoint.toString().replaceAll(RegExp(r'/$'), '')}/$bucket/$fullKey');
    final request = http.Request(method, uri);
    
    // For HEAD and GET, we sign before sending. For PUT, we added headers so we shouldn't sign here.
    if (method != 'PUT') {
      _sign(request, payloadHash);
    }
    
    return request;
  }

  void _sign(http.Request request, String payloadHash) {
    final now = DateTime.now().toUtc();
    final date = _formatDate(now);
    final time = _formatTime(now);

    request.headers['x-amz-date'] = time;
    request.headers['x-amz-content-sha256'] = payloadHash;
    request.headers['host'] = request.url.host;

    final service = 's3';
    final credentialScope = '$date/$region/$service/aws4_request';

    final headerMap = <String, String>{};
    for (final entry in request.headers.entries) {
      headerMap[entry.key.toLowerCase()] = entry.value.trim().replaceAll(RegExp(r'\s+'), ' ');
    }
    final sortedKeys = headerMap.keys.toList()..sort();
    final signedHeaders = sortedKeys.join(';');
    final canonicalHeaders = sortedKeys.map((k) => '$k:${headerMap[k]}\n').join('');

    final canonicalUri = request.url.path;
    final canonicalQueryString = request.url.query;

    final canonicalRequest = [
      request.method,
      canonicalUri,
      canonicalQueryString,
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final stringToSign = [
      'AWS4-HMAC-SHA256',
      time,
      credentialScope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');

    final kDate = _hmac(utf8.encode('AWS4$secretAccessKey'), date);
    final kRegion = _hmac(kDate, region);
    final kService = _hmac(kRegion, service);
    final kSigning = _hmac(kService, 'aws4_request');
    final signature = _hmac(kSigning, stringToSign)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join('');

    final authorization = 'AWS4-HMAC-SHA256 '
        'Credential=$accessKeyId/$credentialScope, '
        'SignedHeaders=$signedHeaders, '
        'Signature=$signature';

    request.headers['Authorization'] = authorization;
  }

  List<int> _hmac(List<int> key, String data) {
    final hmac = Hmac(sha256, key);
    return hmac.convert(utf8.encode(data)).bytes;
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}${dt.month.toString().padLeft(2, '0')}${dt.day.toString().padLeft(2, '0')}';
  }

  String _formatTime(DateTime dt) {
    return '${_formatDate(dt)}T${dt.hour.toString().padLeft(2, '0')}${dt.minute.toString().padLeft(2, '0')}${dt.second.toString().padLeft(2, '0')}Z';
  }
}
