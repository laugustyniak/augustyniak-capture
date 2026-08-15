import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/command/data/http_command_client.dart';
import 'package:augustyniak_capture/features/command/domain/command_client.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Answers from a table instead of a socket, and records what it was asked.
///
/// Hand-written rather than mocked, on the house rule: the suite stays pure
/// Dart, and a fake that records the request is what lets a test assert the
/// URL and the `Authorization` header, which is most of what a client is.
class _FakeHttp extends http.BaseClient {
  _FakeHttp(this.responses);

  /// Path → (status, body).
  final Map<String, (int, String)> responses;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final (int status, String body) =
        responses[request.url.path] ?? (404, '{"error":"no such route"}');
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      status,
      request: request,
    );
  }
}

void main() {
  group('the disabled client', () {
    test('says it is not configured and refuses rather than answering empty', () async {
      const CommandClient client = DisabledCommandClient();
      expect(client.isConfigured, isFalse);
      // Empty and unreachable look identical in a picker, so the default must
      // not be able to produce the first when it means the second.
      expect(client.hosts, throwsA(isA<CommandNotConfiguredException>()));
      expect(
        () => client.workspaces('studio'),
        throwsA(isA<CommandNotConfiguredException>()),
      );
    });
  });

  group('hosts', () {
    test('are read, addressed by id and labelled for people', () async {
      final _FakeHttp http_ = _FakeHttp(<String, (int, String)>{
        '/api/hosts': (
          200,
          '{"hosts":[{"id":"studio","label":"Studio (macOS)"},'
              '{"id":"rack-01"}]}',
        ),
      });
      final List<CommandHost> hosts = await HttpCommandClient(
        baseUrl: Uri.parse('https://fleet.example'),
        bearerToken: 'canary fleet token',
        client: http_,
      ).hosts();

      expect(hosts.map((CommandHost h) => h.id), <String>['studio', 'rack-01']);
      expect(hosts.first.label, 'Studio (macOS)');
      // A host with no label of its own is shown by its id rather than blank.
      expect(hosts.last.label, 'rack-01');
    });

    test('carry the fleet token as a bearer', () async {
      final _FakeHttp http_ = _FakeHttp(<String, (int, String)>{
        '/api/hosts': (200, '[]'),
      });
      await HttpCommandClient(
        baseUrl: Uri.parse('https://fleet.example'),
        bearerToken: 'canary fleet token',
        client: http_,
      ).hosts();

      expect(
        http_.requests.single.headers['Authorization'],
        'Bearer canary fleet token',
      );
    });

    test('a bare array is read as well as an enveloped one', () async {
      final List<CommandHost> hosts = await HttpCommandClient(
        baseUrl: Uri.parse('https://fleet.example'),
        client: _FakeHttp(<String, (int, String)>{
          '/api/hosts': (200, '[{"id":"studio"}]'),
        }),
      ).hosts();

      expect(hosts.single.id, 'studio');
    });

    test('a row this build cannot address is dropped, not guessed at', () async {
      final List<CommandHost> hosts = await HttpCommandClient(
        baseUrl: Uri.parse('https://fleet.example'),
        client: _FakeHttp(<String, (int, String)>{
          '/api/hosts': (
            200,
            '[{"label":"nameless"},{"id":""},{"id":"studio"},"not a host"]',
          ),
        }),
      ).hosts();

      expect(hosts.map((CommandHost h) => h.id), <String>['studio']);
    });
  });

  group('workspaces', () {
    test('are read for one host', () async {
      final _FakeHttp http_ = _FakeHttp(<String, (int, String)>{
        '/api/studio/workspaces': (
          200,
          '{"workspaces":[{"name":"capture","path":"/Users/x/capture"},'
              '{"name":"command"}]}',
        ),
      });
      final List<CommandWorkspace> spaces = await HttpCommandClient(
        baseUrl: Uri.parse('https://fleet.example'),
        client: http_,
      ).workspaces('studio');

      expect(
        spaces.map((CommandWorkspace w) => w.name),
        <String>['capture', 'command'],
      );
      expect(spaces.first.path, '/Users/x/capture');
      expect(spaces.last.path, isNull);
    });
  });

  group('the address', () {
    test('a base path is kept rather than replaced', () async {
      // A reverse-proxy mount is ordinary, and `Uri.resolve` would throw the
      // mount away and ask the proxy's own root for /api/hosts.
      final _FakeHttp http_ = _FakeHttp(<String, (int, String)>{
        '/command/api/hosts': (200, '[]'),
      });
      await HttpCommandClient(
        baseUrl: Uri.parse('https://fleet.example/command/'),
        client: http_,
      ).hosts();

      expect(http_.requests.single.url.path, '/command/api/hosts');
    });
  });

  group('failure', () {
    test('a non-2xx throws with a bounded body', () async {
      final HttpCommandClient client = HttpCommandClient(
        baseUrl: Uri.parse('https://fleet.example'),
        client: _FakeHttp(<String, (int, String)>{
          '/api/hosts': (401, '{"error":"bad fleet token"}'),
        }),
      );

      await expectLater(
        client.hosts,
        throwsA(
          isA<HttpException>().having(
            (HttpException e) => e.message,
            'message',
            allOf(contains('401'), contains('bad fleet token')),
          ),
        ),
      );
    });

    test('a body that is not a list at all throws rather than reading empty', () async {
      final HttpCommandClient client = HttpCommandClient(
        baseUrl: Uri.parse('https://fleet.example'),
        client: _FakeHttp(<String, (int, String)>{
          '/api/hosts': (200, '{"message":"nothing here"}'),
        }),
      );

      await expectLater(client.hosts, throwsFormatException);
    });
  });

  group('project binding', () {
    test('an unbound project serialises exactly as it did before', () {
      const Project project = Project(
        id: 'p1',
        name: 'Acme',
        repoPath: '/tmp/acme',
      );

      expect(project.toJson().keys, <String>[
        'id',
        'name',
        'repoPath',
        'description',
        'sessionName',
        'defaultAgent',
        'agentSettings',
      ]);
      expect(project.isBoundToCommand, isFalse);
    });

    test('a binding round-trips', () {
      final Project bound = const Project(
        id: 'p1',
        name: 'Acme',
        repoPath: '/tmp/acme',
      ).copyWith(
        commandHost: 'studio',
        commandWorkspace: 'capture',
        commandBoundAt: DateTime.utc(2026, 8, 15, 9),
      );

      final Project read = Project.fromJson(bound.toJson());
      expect(read.commandHost, 'studio');
      expect(read.commandWorkspace, 'capture');
      expect(read.commandBoundAt, DateTime.utc(2026, 8, 15, 9));
      expect(read.isBoundToCommand, isTrue);
    });

    test('half a binding is not a binding', () {
      const Project hostOnly = Project(
        id: 'p1',
        name: 'Acme',
        repoPath: '/tmp/acme',
        commandHost: 'studio',
      );
      expect(hostOnly.isBoundToCommand, isFalse);
    });

    test('clearing removes all three at once', () {
      final Project cleared = const Project(
        id: 'p1',
        name: 'Acme',
        repoPath: '/tmp/acme',
        commandHost: 'studio',
        commandWorkspace: 'capture',
      ).copyWith(clearCommandBinding: true);

      expect(cleared.commandHost, isNull);
      expect(cleared.commandWorkspace, isNull);
      expect(cleared.commandBoundAt, isNull);
      expect(cleared.toJson().containsKey('commandHost'), isFalse);
    });

    test('a row from a newer build loads instead of being dropped', () {
      final Project read = Project.fromJson(<String, dynamic>{
        'id': 'p1',
        'name': 'Acme',
        'repoPath': '/tmp/acme',
        'commandHost': 'studio',
        'commandWorkspace': 'capture',
        'commandBoundAt': 'not a timestamp',
        'commandFleetRegion': 'eu-central',
      });

      expect(read.isBoundToCommand, isTrue);
      // An unparseable stamp costs the binding's age, never the binding: the
      // pair is what addresses the work.
      expect(read.commandBoundAt, isNull);
    });
  });
}
