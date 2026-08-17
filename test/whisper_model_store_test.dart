import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/transcription/data/whisper_model_store.dart';
import 'package:augustyniak_capture/features/transcription/domain/whisper_model.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Serves bytes from a table instead of the network, and can lie about the
/// length the way a dropped connection does.
class _FakeHttp extends http.BaseClient {
  _FakeHttp({
    this.body = const <int>[],
    this.status = 200,
    this.declaredLength,
    this.chunks = 1,
    this.stall,
  });

  final List<int> body;
  final int status;

  /// What `Content-Length` promises. Null omits the header entirely, which is
  /// what a chunked response does.
  final int? declaredLength;

  /// How many pieces the body arrives in — a download that reports progress
  /// only at the end is indistinguishable from one that reports none.
  final int chunks;

  /// Held between chunks, so a test can cancel mid-transfer.
  final Future<void>? stall;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final int size = (body.length / chunks).ceil().clamp(1, body.length + 1);
    Stream<List<int>> pieces() async* {
      for (int at = 0; at < body.length; at += size) {
        yield body.sublist(at, (at + size).clamp(0, body.length));
        if (stall != null) await stall;
      }
    }

    return http.StreamedResponse(
      body.isEmpty ? const Stream<List<int>>.empty() : pieces(),
      status,
      contentLength: declaredLength,
      request: request,
    );
  }
}

WhisperModel _model({String? sha256Pin, int approximateBytes = 8}) =>
    WhisperModel(
      id: 'test-model',
      label: 'Test',
      url: Uri.parse('https://models.invalid/ggml-test-model.bin'),
      approximateBytes: approximateBytes,
      note: 'a fixture',
      sha256: sha256Pin,
    );

void main() {
  late Directory dir;
  final List<int> payload = utf8.encode('a model, in bytes');
  final String payloadHash = sha256.convert(payload).toString();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('augustyniak_models_');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  WhisperModelStore storeWith(http.Client client) => WhisperModelStore(
    directoryProvider: () async => Directory(p.join(dir.path, 'speech-models')),
    client: client,
  );

  group('installing', () {
    test('a whole download is verified, renamed and reported', () async {
      final WhisperModelStore store = storeWith(
        _FakeHttp(body: payload, declaredLength: payload.length),
      );

      final InstalledModel installed = await store.download(
        _model(sha256Pin: payloadHash),
      );

      expect(installed.bytes, payload.length);
      expect(installed.verified, isTrue);
      expect(File(installed.path).readAsBytesSync(), payload);
      expect(await store.pathFor('test-model'), installed.path);
      // Nothing partial is left behind.
      expect(
        File('${installed.path}${WhisperModelStore.partialSuffix}').existsSync(),
        isFalse,
      );
    });

    test('progress is reported while streaming, not only at the end', () async {
      final WhisperModelStore store = storeWith(
        _FakeHttp(body: payload, declaredLength: payload.length, chunks: 4),
      );
      final List<int> seen = <int>[];

      await store.download(
        _model(),
        onProgress: (ModelDownloadProgress progress) =>
            seen.add(progress.received),
      );

      expect(seen.length, greaterThan(1));
      expect(seen.last, payload.length);
      // Monotonic, and the last one is the whole file.
      expect(seen, orderedEquals(<int>[...seen]..sort()));
    });

    test('an unpinned model installs, and says it was not verified', () async {
      // The honest state of every catalog entry this app currently ships: a
      // hash can only be stated by downloading the file once, and inventing one
      // would be worse than admitting there is none.
      final WhisperModelStore store = storeWith(
        _FakeHttp(body: payload, declaredLength: payload.length),
      );

      final InstalledModel installed = await store.download(_model());
      expect(installed.verified, isFalse);
      expect(File(installed.path).existsSync(), isTrue);
    });

    test('an already installed model is not fetched again', () async {
      final WhisperModelStore store = storeWith(
        _FakeHttp(body: payload, declaredLength: payload.length),
      );
      await store.download(_model());

      // A client that would fail if it were asked at all.
      final WhisperModelStore second = storeWith(_FakeHttp(status: 500));
      final InstalledModel installed = await second.download(_model());
      expect(installed.bytes, payload.length);
    });
  });

  group('refusing', () {
    test('a truncated download never becomes an installed model', () async {
      // The server promised more than it sent — the shape a dropped connection
      // takes. Nothing in the catalog is consulted for this: the check is what
      // arrived against what was promised, which cannot go stale.
      final WhisperModelStore store = storeWith(
        _FakeHttp(body: payload, declaredLength: payload.length + 10),
      );

      await expectLater(
        store.download(_model()),
        throwsA(isA<ModelDownloadException>()),
      );
      expect(await store.pathFor('test-model'), isNull);
      final String planned = await store.plannedPath('test-model');
      expect(
        File('$planned${WhisperModelStore.partialSuffix}').existsSync(),
        isFalse,
        reason: 'the partial file must not survive to be resumed blindly',
      );
    });

    test('a hash mismatch is refused and the partial removed', () async {
      final WhisperModelStore store = storeWith(
        _FakeHttp(body: payload, declaredLength: payload.length),
      );

      await expectLater(
        store.download(_model(sha256Pin: 'd' * 64)),
        throwsA(
          isA<ModelDownloadException>().having(
            (ModelDownloadException e) => e.toString(),
            'message',
            contains('checksum'),
          ),
        ),
      );
      expect(await store.pathFor('test-model'), isNull);
      final String planned = await store.plannedPath('test-model');
      expect(
        File('$planned${WhisperModelStore.partialSuffix}').existsSync(),
        isFalse,
      );
    });

    test('a non-2xx never writes anything', () async {
      final WhisperModelStore store = storeWith(_FakeHttp(status: 404));

      await expectLater(
        store.download(_model()),
        throwsA(isA<ModelDownloadException>()),
      );
      expect(await store.pathFor('test-model'), isNull);
    });

    test('a cancelled download leaves nothing behind', () async {
      final Completer<void> cancel = Completer<void>();
      final Completer<void> between = Completer<void>();
      final WhisperModelStore store = storeWith(
        _FakeHttp(
          body: payload,
          declaredLength: payload.length,
          chunks: 4,
          stall: between.future,
        ),
      );

      final Future<InstalledModel> pending = store.download(
        _model(),
        cancelledBy: cancel.future,
        onProgress: (ModelDownloadProgress _) {
          if (!cancel.isCompleted) cancel.complete();
        },
      );
      // Let the cancel land, then release the stream.
      await Future<void>.delayed(Duration.zero);
      between.complete();

      await expectLater(pending, throwsA(isA<ModelDownloadCancelled>()));
      expect(await store.pathFor('test-model'), isNull);
      final String planned = await store.plannedPath('test-model');
      expect(
        File('$planned${WhisperModelStore.partialSuffix}').existsSync(),
        isFalse,
      );
    });
  });

  group('listing and deleting', () {
    test('installed is answered from disk, not from a remembered list', () async {
      final WhisperModelStore store = storeWith(
        _FakeHttp(body: payload, declaredLength: payload.length),
      );
      await store.download(_model());
      final String path = (await store.pathFor('test-model'))!;

      // Removed behind the store's back, the way a user with a file manager or
      // a phone reclaiming space would.
      File(path).deleteSync();

      expect(await store.pathFor('test-model'), isNull);
    });

    test('delete reclaims the bytes and says whether there was anything', () async {
      final WhisperModelStore store = storeWith(
        _FakeHttp(body: payload, declaredLength: payload.length),
      );
      await store.download(_model());

      expect(await store.delete('test-model'), isTrue);
      expect(await store.pathFor('test-model'), isNull);
      // "It is gone now" and "it was never there" are different answers.
      expect(await store.delete('test-model'), isFalse);
    });

    test('installed lists only catalog models that are actually there', () async {
      final WhisperModelStore store = storeWith(_FakeHttp());
      expect(await store.installed(), isEmpty);
    });
  });

  group('the catalog', () {
    test('ids are unique and name the file on disk', () {
      final Set<String> ids = <String>{
        for (final WhisperModel model in WhisperModelCatalog.all) model.id,
      };
      expect(ids.length, WhisperModelCatalog.all.length);
      for (final WhisperModel model in WhisperModelCatalog.all) {
        expect(model.fileName, 'ggml-${model.id}.bin');
        expect(model.url.toString(), endsWith(model.fileName));
        expect(model.note, isNotEmpty);
      }
    });

    test('an id this build does not ship resolves to null', () {
      // The same dangling-reference shape as a deleted project on a capture:
      // a profile naming a retired model must degrade, not throw.
      expect(WhisperModelCatalog.byId('no-such-model'), isNull);
      expect(WhisperModelCatalog.byId('base-q5_1'), isNotNull);
    });

    test('every shipped entry is honest about being unpinned', () {
      // Pinning is a follow-up that requires downloading each file once. Until
      // then the store reports the install as unverified rather than implying a
      // check that never ran.
      for (final WhisperModel model in WhisperModelCatalog.all) {
        expect(
          model.sha256,
          isNull,
          reason:
              'a pinned hash must be measured, not written from memory — if '
              'this fails, the pin was added and this expectation should '
              'become a format check',
        );
      }
    });
  });
}
