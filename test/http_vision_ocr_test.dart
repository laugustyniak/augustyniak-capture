import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:audivoa_core/features/processing/data/http_vision_ocr_service.dart';
import 'package:audivoa_core/features/processing/data/ocr_service.dart';
import 'package:audivoa_core/features/settings/domain/provider_profile.dart';

const List<int> _pngMagic = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0,
  0,
  0,
  0,
];
const List<int> _jpegMagic = <int>[
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
];

String _chatBody(String content) => jsonEncode(<String, dynamic>{
  'choices': <Map<String, dynamic>>[
    <String, dynamic>{
      'message': <String, dynamic>{'role': 'assistant', 'content': content},
    },
  ],
});

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vision_ocr_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<File> writeImage(String name, List<int> bytes) async {
    final File file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  group('HttpVisionOcrService request', () {
    test('sends data URL, model, instruction and bearer token', () async {
      late http.Request seen;
      final HttpVisionOcrService service = HttpVisionOcrService(
        endpoint: Uri.parse('https://api.example.com/v1/chat/completions'),
        bearerToken: 'sk-test',
        model: 'gpt-4o-mini',
        client: MockClient((http.Request request) async {
          seen = request;
          return http.Response(_chatBody('Hello world'), 200);
        }),
      );

      final File image = await writeImage('scan.png', _pngMagic);
      final String text = await service.extractText(image);

      expect(text, 'Hello world');
      expect(seen.headers['Authorization'], 'Bearer sk-test');
      final Map<String, dynamic> payload =
          jsonDecode(utf8.decode(seen.bodyBytes)) as Map<String, dynamic>;
      expect(payload['model'], 'gpt-4o-mini');
      final List<dynamic> content =
          ((payload['messages'] as List<dynamic>).single
                  as Map<String, dynamic>)['content']
              as List<dynamic>;
      final Map<String, dynamic> imagePart =
          content.first as Map<String, dynamic>;
      expect(imagePart['type'], 'image_url');
      expect(
        (imagePart['image_url'] as Map<String, dynamic>)['url'],
        startsWith('data:image/png;base64,'),
      );
      final Map<String, dynamic> textPart =
          content.last as Map<String, dynamic>;
      expect(textPart['type'], 'text');
      expect(textPart['text'], contains('Transcribe'));
    });

    test('omits model and auth header when unset', () async {
      late http.Request seen;
      final HttpVisionOcrService service = HttpVisionOcrService(
        endpoint: Uri.parse('https://api.example.com/v1/chat/completions'),
        client: MockClient((http.Request request) async {
          seen = request;
          return http.Response(_chatBody('ok'), 200);
        }),
      );

      await service.extractText(await writeImage('scan.jpg', _jpegMagic));

      expect(seen.headers.containsKey('Authorization'), isFalse);
      final Map<String, dynamic> payload =
          jsonDecode(utf8.decode(seen.bodyBytes)) as Map<String, dynamic>;
      expect(payload.containsKey('model'), isFalse);
    });

    test('magic bytes win over a lying extension', () async {
      late http.Request seen;
      final HttpVisionOcrService service = HttpVisionOcrService(
        endpoint: Uri.parse('https://api.example.com/v1/chat/completions'),
        client: MockClient((http.Request request) async {
          seen = request;
          return http.Response(_chatBody('ok'), 200);
        }),
      );

      // PNG bytes stored as .jpg — what the import path produces for an
      // unknown-extension image.
      await service.extractText(await writeImage('mislabeled.jpg', _pngMagic));

      expect(utf8.decode(seen.bodyBytes), contains('data:image/png;base64'));
    });
  });

  group('HttpVisionOcrService errors', () {
    test('missing file throws FileSystemException', () {
      final HttpVisionOcrService service = HttpVisionOcrService(
        endpoint: Uri.parse('https://api.example.com/v1/chat/completions'),
        client: MockClient((_) async => http.Response(_chatBody('x'), 200)),
      );
      expect(
        () => service.extractText(File('${tempDir.path}/absent.png')),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('oversize file is rejected before any request', () async {
      final HttpVisionOcrService service = HttpVisionOcrService(
        endpoint: Uri.parse('https://api.example.com/v1/chat/completions'),
        client: MockClient((_) async => fail('must not reach the network')),
      );
      final File big = File('${tempDir.path}/big.png');
      final RandomAccessFile raf = await big.open(mode: FileMode.write);
      await raf.truncate(HttpVisionOcrService.maxImageBytes + 1);
      await raf.close();

      expect(
        () => service.extractText(big),
        throwsA(
          isA<FileSystemException>().having(
            (FileSystemException e) => e.message,
            'message',
            contains('too large'),
          ),
        ),
      );
    });

    test('non-2xx throws HttpException with the body', () async {
      final HttpVisionOcrService service = HttpVisionOcrService(
        endpoint: Uri.parse('https://api.example.com/v1/chat/completions'),
        client: MockClient(
          (_) async => http.Response('{"error":"invalid_api_key"}', 401),
        ),
      );
      expect(
        () async =>
            service.extractText(await writeImage('scan.png', _pngMagic)),
        throwsA(
          isA<HttpException>().having(
            (HttpException e) => e.message,
            'message',
            allOf(contains('401'), contains('invalid_api_key')),
          ),
        ),
      );
    });

    test('non-chat-shaped body throws FormatException', () async {
      final HttpVisionOcrService service = HttpVisionOcrService(
        endpoint: Uri.parse('https://api.example.com/v1/chat/completions'),
        client: MockClient((_) async => http.Response('{"choices":[]}', 200)),
      );
      expect(
        () async =>
            service.extractText(await writeImage('scan.png', _pngMagic)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('parseResponse', () {
    test('strips a markdown fence', () {
      expect(
        HttpVisionOcrService.parseResponse(
          _chatBody('```\nline one\nline two\n```'),
        ),
        'line one\nline two',
      );
    });

    test('non-object body throws', () {
      expect(
        () => HttpVisionOcrService.parseResponse('[1,2]'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('sniffImageMime', () {
    test('recognises the supported formats', () {
      expect(
        HttpVisionOcrService.sniffImageMime(_jpegMagic, 'x.bin'),
        'image/jpeg',
      );
      expect(
        HttpVisionOcrService.sniffImageMime(_pngMagic, 'x.bin'),
        'image/png',
      );
      expect(
        HttpVisionOcrService.sniffImageMime(<int>[
          0x52,
          0x49,
          0x46,
          0x46,
          0,
          0,
          0,
          0,
          0x57,
          0x45,
          0x42,
          0x50,
        ], 'x.bin'),
        'image/webp',
      );
      expect(
        HttpVisionOcrService.sniffImageMime(<int>[
          0,
          0,
          0,
          0x18,
          0x66,
          0x74,
          0x79,
          0x70,
          0x68,
          0x65,
          0x69,
          0x63,
        ], 'x.bin'),
        'image/heic',
      );
    });

    test('falls back to extension, then jpeg', () {
      expect(
        HttpVisionOcrService.sniffImageMime(<int>[], 'a.webp'),
        'image/webp',
      );
      expect(
        HttpVisionOcrService.sniffImageMime(<int>[], 'a.unknown'),
        'image/jpeg',
      );
    });
  });

  group('ProviderProfile.toOcrService', () {
    test('configured enrichment profile yields the HTTP service', () {
      const ProviderProfile profile = ProviderProfile(
        id: 'p1',
        name: 'OpenAI',
        kind: ProfileKind.enrichment,
        endpoint: 'https://api.openai.com/v1/chat/completions',
        model: 'gpt-4o-mini',
      );
      expect(profile.toOcrService(), isA<HttpVisionOcrService>());
    });

    test('blank and schemeless endpoints degrade to disabled', () {
      const ProviderProfile blank = ProviderProfile(
        id: 'p1',
        name: 'x',
        kind: ProfileKind.enrichment,
        endpoint: '   ',
      );
      const ProviderProfile schemeless = ProviderProfile(
        id: 'p2',
        name: 'x',
        kind: ProfileKind.enrichment,
        endpoint: 'api.example.com/v1/chat/completions',
      );
      expect(blank.toOcrService(), isA<DisabledOcrService>());
      expect(schemeless.toOcrService(), isA<DisabledOcrService>());
    });
  });
}
