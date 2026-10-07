import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:augustyniak_capture/features/enrichment/data/http_embedding_service.dart';
import 'package:augustyniak_capture/features/enrichment/domain/embedding_service.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_service.dart';
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/data/sqlite_embedding_store.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/related_captures.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

/// A bag-of-words "embedding" over a fixed vocabulary: deterministic, and
/// close for texts that share the words that matter.
class _WordEmbeddings implements EmbeddingService {
  _WordEmbeddings({this.model = 'words-1'});

  static const List<String> vocabulary = <String>[
    'client',
    'offer',
    'invoice',
    'garden',
    'water',
    'gpu',
  ];

  @override
  final String model;
  int calls = 0;
  bool fail = false;

  @override
  Future<List<double>> embed(String text) async {
    calls++;
    if (fail) throw const HttpException('endpoint down');
    final List<String> words = text.toLowerCase().split(RegExp(r'\W+'));
    return <double>[
      for (final String term in vocabulary)
        words.where((String w) => w == term).length.toDouble(),
    ];
  }
}

class _FakeRepo extends RecordingsRepository {
  _FakeRepo(this._dir, this.saved);
  final Directory _dir;
  List<Recording> saved;

  @override
  Future<Directory> recordingsDirectory() async => _dir;

  @override
  Future<List<Recording>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<Recording> recordings) async =>
      saved = List<Recording>.from(recordings);

  @override
  Future<void> deleteArtifacts(Recording recording) async {}
}

class _EchoProcessor implements Processor {
  const _EchoProcessor();

  @override
  Future<String> process(CaptureSegment segment) async =>
      File(segment.filePath).readAsString();
}

Recording _capture(String id, String transcript, {DateTime? at}) => Recording(
  id: id,
  filePath: '/tmp/$id.m4a',
  createdAt: at ?? DateTime(2026, 10, 7),
  durationMs: 1000,
  status: RecordingStatus.completed,
  transcript: transcript,
);

String _chatEnvelope(List<Object?> vector) => jsonEncode(<String, dynamic>{
  'data': <dynamic>[
    <String, dynamic>{'embedding': vector, 'index': 0},
  ],
  'usage': <String, int>{'prompt_tokens': 5, 'total_tokens': 5},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final String name in <String>[
    'com.llfbandit.record/messages',
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          MethodChannel(name),
          (MethodCall call) async => null,
        );
  }

  group('cosine', () {
    test('identical is 1, orthogonal 0, malformed never related', () {
      expect(cosine(<double>[1, 2], <double>[1, 2]), closeTo(1, 1e-9));
      expect(cosine(<double>[1, 0], <double>[0, 1]), 0);
      expect(cosine(<double>[1, 0], <double>[1, 0, 0]), 0);
      expect(cosine(<double>[0, 0], <double>[1, 0]), 0);
    });
  });

  group('rankRelated', () {
    test(
      'excludes itself and the unrelated, best first, duplicates flagged',
      () {
        final List<RelatedCapture> found = rankRelated(
          'a',
          <String, List<double>>{
            'a': <double>[1, 1, 0],
            'same': <double>[1, 1, 0],
            'near': <double>[1, 0.3, 0],
            'far': <double>[0, 0, 1],
          },
        );
        expect(found.map((RelatedCapture r) => r.id), <String>['same', 'near']);
        expect(found.first.duplicate, isTrue);
        expect(found.last.duplicate, isFalse);
      },
    );

    test('keeps at most topN', () {
      final Map<String, List<double>> many = <String, List<double>>{
        for (int i = 0; i < 10; i++) 'c$i': <double>[1, i / 100],
      };
      expect(rankRelated('c0', many), hasLength(RelatedLimits.topN));
    });

    test('no vector of its own means nothing related', () {
      expect(
        rankRelated('x', <String, List<double>>{
          'a': <double>[1],
        }),
        isEmpty,
      );
    });
  });

  test('embeddingInput skips blank text and keeps only the head', () {
    expect(embeddingInput(_capture('a', '   ')), isNull);
    final String long = 'x' * (RelatedLimits.maxChars + 50);
    expect(
      embeddingInput(_capture('a', long)),
      hasLength(RelatedLimits.maxChars),
    );
  });

  group('embeddingsEndpointFor', () {
    test('sits beside a chat endpoint, and refuses to guess otherwise', () {
      expect(
        embeddingsEndpointFor(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
        ).toString(),
        'https://api.openai.com/v1/embeddings',
      );
      expect(
        embeddingsEndpointFor(
          Uri.parse('http://localhost:11434/v1/chat/completions/'),
        ).toString(),
        'http://localhost:11434/v1/embeddings',
      );
      expect(
        embeddingsEndpointFor(Uri.parse('https://x.dev/api/chat')),
        isNull,
      );
    });
  });

  group('HttpEmbeddingService', () {
    HttpEmbeddingService service(
      String body, {
      int status = 200,
      List<Map<String, dynamic>>? sent,
    }) => HttpEmbeddingService(
      endpoint: Uri.parse('https://api.example.com/v1/embeddings'),
      model: 'text-embedding-3-small',
      client: MockClient((http.Request request) async {
        sent?.add(
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>,
        );
        return http.Response.bytes(utf8.encode(body), status);
      }),
    );

    test('sends the model and the text, returns the vector', () async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final List<double> vector = await service(
        _chatEnvelope(<Object>[0.5, -1, 2]),
        sent: sent,
      ).embed('call the client');
      expect(vector, <double>[0.5, -1, 2]);
      expect(sent.single['model'], 'text-embedding-3-small');
      expect(sent.single['input'], 'call the client');
    });

    test('refuses a malformed vector rather than storing it', () async {
      await expectLater(
        service(_chatEnvelope(<Object>[])).embed('x'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        service(_chatEnvelope(<Object>[1, 'two'])).embed('x'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        service('{"data": []}').embed('x'),
        throwsA(isA<FormatException>()),
      );
      // 1e999 decodes to infinity, which would poison every cosine after it.
      await expectLater(
        service('{"data": [{"embedding": [1, 1e999]}]}').embed('x'),
        throwsA(isA<FormatException>()),
      );
    });

    test('a provider error is an HttpException', () async {
      await expectLater(
        service('{"error": "nope"}', status: 401).embed('x'),
        throwsA(isA<HttpException>()),
      );
    });
  });

  group('SqliteEmbeddingStore', () {
    late Database db;
    late SqliteEmbeddingStore store;

    setUp(() {
      db = sqlite3.openInMemory();
      SqliteEmbeddingStore.createTable(db);
      store = SqliteEmbeddingStore(db);
    });
    tearDown(() => db.close());

    StoredEmbedding vector(String id, String model, List<double> v) =>
        StoredEmbedding(
          captureId: id,
          fingerprint: 'fp-$id',
          model: model,
          vector: Float32List.fromList(v),
        );

    test('round-trips per model and removes by capture', () {
      store.put(vector('a', 'm1', <double>[1, 2.5]));
      store.put(vector('a', 'm2', <double>[9]));
      store.put(vector('b', 'm1', <double>[0, 1]));

      final Map<String, StoredEmbedding> m1 = store.load('m1');
      expect(m1.keys, unorderedEquals(<String>['a', 'b']));
      expect(m1['a']!.vector, <double>[1, 2.5]);
      expect(m1['a']!.fingerprint, 'fp-a');
      expect(store.load('m2')['a']!.vector, <double>[9]);

      store.remove('a');
      expect(store.load('m1').keys, <String>['b']);
      expect(store.load('m2'), isEmpty);
    });

    test('an unreadable row is dropped, not the table', () {
      store.put(vector('a', 'm1', <double>[1]));
      db.execute(
        "INSERT INTO capture_embeddings VALUES ('bad', 'm1', 'fp', x'0102')",
      );
      expect(store.load('m1').keys, <String>['a']);
    });
  });

  group('settings', () {
    test('embeddingModel stays out of the JSON until set, blank is unset', () {
      expect(AppSettings.empty.toJson().containsKey('embeddingModel'), isFalse);
      const AppSettings set = AppSettings(
        embeddingModel: 'text-embedding-3-small',
      );
      expect(
        AppSettings.fromJson(set.toJson()).embeddingModel,
        'text-embedding-3-small',
      );
      expect(
        AppSettings.fromJson(<String, dynamic>{
          'embeddingModel': '  ',
        }).embeddingModel,
        isNull,
      );
    });

    test('a profile with no chat path gives no embedding service', () {
      ProviderProfile profile(String endpoint) => ProviderProfile(
        id: 'p',
        name: 'p',
        endpoint: endpoint,
        kind: ProfileKind.enrichment,
      );
      expect(
        profile('https://x.dev/api/chat').toEmbeddingService(model: 'e'),
        isA<DisabledEmbeddingService>(),
      );
      final EmbeddingService real = profile(
        'https://api.openai.com/v1/chat/completions',
      ).toEmbeddingService(model: 'e');
      expect(real, isA<HttpEmbeddingService>());
      expect((real as HttpEmbeddingService).endpoint.path, '/v1/embeddings');
    });
  });

  group('RecordingsController', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('related_ctrl'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<RecordingsController> build(
      List<Recording> seed, {
      EmbeddingService? embeddings,
      EmbeddingStore? store,
      _FakeRepo? repo,
    }) async {
      final RecordingsController c = RecordingsController(
        repository: repo ?? _FakeRepo(dir, seed),
        transcriptionService: const DisabledTranscriptionService(),
        enrichmentService: const DisabledEnrichmentService(),
        processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
          CaptureType.audioRecording: const _EchoProcessor(),
        }),
      );
      if (store != null) c.embeddingStore = store;
      if (embeddings != null) c.embeddingService = embeddings;
      addTearDown(c.dispose);
      await c.initialize();
      return c;
    }

    final List<Recording> library = <Recording>[
      _capture('a', 'call the client about the offer'),
      _capture('b', 'send the client the offer and the invoice'),
      _capture('c', 'water the garden'),
    ];

    test(
      'without an embedding model nothing is related and nothing is sent',
      () async {
        final RecordingsController c = await build(library);
        expect(c.relatedEnabled, isFalse);
        expect(await c.buildIndex(), 0);
        expect(c.relatedFor('a'), isEmpty);
        expect(c.unindexedIds(), isEmpty);
      },
    );

    test(
      'an index build finds the related capture and not the unrelated',
      () async {
        final _WordEmbeddings embeddings = _WordEmbeddings();
        final RecordingsController c = await build(
          library,
          embeddings: embeddings,
        );
        expect(c.unindexedIds(), hasLength(3));

        expect(await c.buildIndex(), 3);
        expect(embeddings.calls, 3);
        expect(c.relatedFor('a').map((RelatedCapture r) => r.id), <String>[
          'b',
        ]);
        expect(c.relatedFor('c'), isEmpty);

        // Nothing left to do: a second build sends nothing.
        expect(await c.buildIndex(), 0);
        expect(embeddings.calls, 3);
      },
    );

    test('a finished processing job embeds the capture', () async {
      File('${dir.path}/n.m4a').writeAsStringSync('a new client offer');
      final _WordEmbeddings embeddings = _WordEmbeddings();
      final RecordingsController c = await build(<Recording>[
        library.first,
        Recording(
          id: 'n',
          filePath: '${dir.path}/n.m4a',
          createdAt: DateTime(2026, 10, 7),
          durationMs: 1000,
          status: RecordingStatus.failed,
        ),
      ], embeddings: embeddings);
      await c.buildIndex();

      await c.retryTranscription('n');
      await c.waitForProcessing();

      expect(
        c.recordings.firstWhere((Recording r) => r.id == 'n').status,
        RecordingStatus.completed,
      );
      expect(c.relatedFor('n').map((RelatedCapture r) => r.id), <String>['a']);
    });

    test('an edited transcript is never matched by its old vector', () async {
      final _WordEmbeddings embeddings = _WordEmbeddings();
      final RecordingsController c = await build(
        library,
        embeddings: embeddings,
      );
      await c.buildIndex();
      expect(c.relatedFor('a').map((RelatedCapture r) => r.id), <String>['b']);

      // The re-embed after the edit fails, so only the old vector exists.
      embeddings.fail = true;
      await c.editTranscript('b', 'water the garden twice');

      expect(c.relatedFor('a'), isEmpty);
      expect(c.relatedFor('b'), isEmpty);
      expect(c.unindexedIds(), <String>['b']);
    });

    test('an edit is re-embedded and found by what it says now', () async {
      final _WordEmbeddings embeddings = _WordEmbeddings();
      final RecordingsController c = await build(
        library,
        embeddings: embeddings,
      );
      await c.buildIndex();

      await c.editTranscript('b', 'water the garden twice');

      expect(c.relatedFor('c').map((RelatedCapture r) => r.id), <String>['b']);
      expect(c.relatedFor('a'), isEmpty);
    });

    test('vectors from another model are never compared', () async {
      final InMemoryEmbeddingStore store = InMemoryEmbeddingStore();
      final RecordingsController c = await build(
        library,
        embeddings: _WordEmbeddings(),
        store: store,
      );
      await c.buildIndex();

      c.embeddingService = _WordEmbeddings(model: 'words-2');

      expect(c.relatedFor('a'), isEmpty);
      expect(c.unindexedIds(), hasLength(3));
    });

    test('vectors survive a restart through the store', () async {
      final InMemoryEmbeddingStore store = InMemoryEmbeddingStore();
      final RecordingsController first = await build(
        library,
        embeddings: _WordEmbeddings(),
        store: store,
      );
      await first.buildIndex();

      final _WordEmbeddings again = _WordEmbeddings();
      final RecordingsController second = await build(
        library,
        embeddings: again,
        store: store,
      );
      expect(second.relatedFor('a').map((RelatedCapture r) => r.id), <String>[
        'b',
      ]);
      expect(again.calls, 0);
    });

    test('a failing endpoint costs the vector, never the capture', () async {
      final _WordEmbeddings embeddings = _WordEmbeddings()..fail = true;
      final RecordingsController c = await build(
        library,
        embeddings: embeddings,
      );

      expect(await c.buildIndex(), 0);
      expect(c.indexProgress, isNull);
      expect(
        c.recordings.map((Recording r) => r.status),
        everyElement(RecordingStatus.completed),
      );
      expect(c.relatedFor('a'), isEmpty);
    });

    test(
      'the same thought said three times in two weeks counts three',
      () async {
        final DateTime now = DateTime(2026, 10, 7);
        final RecordingsController c = await build(<Recording>[
          _capture('a', 'client offer', at: now),
          _capture(
            'b',
            'the client offer again',
            at: now.subtract(const Duration(days: 3)),
          ),
          _capture(
            'c',
            'client offer, once more',
            at: now.subtract(const Duration(days: 10)),
          ),
          _capture(
            'old',
            'client offer',
            at: now.subtract(const Duration(days: 40)),
          ),
          _capture('x', 'water the garden', at: now),
        ], embeddings: _WordEmbeddings());
        await c.buildIndex();

        expect(c.repeatCount('a'), 3);
        expect(c.repeatCount('x'), 1);
      },
    );

    test('deleting a capture drops its vector', () async {
      final InMemoryEmbeddingStore store = InMemoryEmbeddingStore();
      final RecordingsController c = await build(
        library,
        embeddings: _WordEmbeddings(),
        store: store,
      );
      await c.buildIndex();

      await c.deleteRecording('b');

      expect(store.load('words-1').keys, isNot(contains('b')));
      expect(c.relatedFor('a'), isEmpty);
    });
  });
}
