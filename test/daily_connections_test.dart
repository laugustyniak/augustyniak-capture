import 'dart:convert';

import 'package:augustyniak_capture/features/connections/data/http_daily_connections_service.dart';
import 'package:augustyniak_capture/features/connections/domain/daily_connections.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_parsing.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Recording capture(String id, DateTime day, String? text, {bool done = false}) =>
    Recording(
      id: id,
      isProcessedByUser: done,
      filePath: '/tmp/$id.txt',
      createdAt: day,
      durationMs: 0,
      status: RecordingStatus.completed,
      type: CaptureType.text,
      transcript: text,
    );

void main() {
  final DateTime day = DateTime(2026, 10, 3);
  final List<Recording> recordings = <Recording>[
    capture('one', DateTime(2026, 10, 3, 8), 'Ulepszyć wyszukiwanie'),
    capture('two', DateTime(2026, 10, 3, 20), 'Indeks wyszukiwania'),
    capture('blank', DateTime(2026, 10, 3, 21), '   '),
    capture('yesterday', DateTime(2026, 10, 2, 23), 'Poprzedni dzień'),
  ];

  test('local day selection includes every text-ready capture only', () {
    expect(capturesOnDay(recordings, day).map((Recording r) => r.id), <String>[
      'one',
      'two',
    ]);
  });

  test('open selection takes every not-done text-ready capture, any day', () {
    final List<Recording> desk = <Recording>[
      ...recordings,
      capture('done', DateTime(2026, 9, 1), 'Already handled', done: true),
      capture('old', DateTime(2025, 1, 1), 'Still open from last year'),
    ];
    expect(
      capturesInScope(
        desk,
        const ConnectionsScope.open(),
      ).map((Recording r) => r.id),
      <String>['one', 'two', 'yesterday', 'old'],
    );
    expect(
      capturesInScope(
        desk,
        ConnectionsScope.day(day),
      ).map((Recording r) => r.id),
      <String>['one', 'two'],
    );
  });

  test(
    'open review sends exactly the open captures and files open usage',
    () async {
      late List<dynamic> sent;
      bool? reportedOpen;
      final HttpDailyConnectionsService service = HttpDailyConnectionsService(
        recordUsage:
            ({
              required day,
              required openCaptures,
              required provider,
              required model,
              required usage,
            }) => reportedOpen = openCaptures,
        activeProfile: () => const ProviderProfile(
          id: 'p',
          name: 'Model',
          endpoint: 'https://example.com/v1/chat/completions',
          kind: ProfileKind.enrichment,
        ),
        client: MockClient((http.Request request) async {
          final Map<String, dynamic> body =
              jsonDecode(utf8.decode(request.bodyBytes))
                  as Map<String, dynamic>;
          sent =
              jsonDecode(
                    ((body['messages'] as List<dynamic>).last
                            as Map<String, dynamic>)['content']
                        as String,
                  )
                  as List<dynamic>;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'usage': <String, int>{
                'prompt_tokens': 1,
                'completion_tokens': 1,
              },
              'choices': <dynamic>[
                <String, dynamic>{
                  'message': <String, dynamic>{
                    'content': jsonEncode(<String, dynamic>{
                      'groups': <dynamic>[],
                    }),
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      final DailyConnectionsReport report = await service.review(
        const ConnectionsScope.open(),
        <Recording>[
          ...recordings,
          capture('done', DateTime(2026, 9, 1), 'Handled', done: true),
        ],
      );
      expect(sent.map((dynamic c) => c['id']), <String>[
        'one',
        'two',
        'yesterday',
      ]);
      expect(report.scope.isOpen, isTrue);
      expect(reportedOpen, isTrue);
      service.close();
    },
  );

  test('excerpts shrink to the text budget but keep every capture', () {
    expect(HttpDailyConnectionsService.excerptLimit(1), 2000);
    expect(HttpDailyConnectionsService.excerptLimit(60), 2000);
    expect(HttpDailyConnectionsService.excerptLimit(61), 1967);
    expect(HttpDailyConnectionsService.excerptLimit(600), 200);
    expect(HttpDailyConnectionsService.excerptLimit(100), 1200);
    expect(HttpDailyConnectionsService.excerptLimit(5000), 200);
    final String text = '${'a' * 1500}MIDDLE${'z' * 1500}';
    expect(
      HttpDailyConnectionsService.excerpt(text, 2000),
      '${'a' * 1300}\n[…]\n${'z' * 700}',
    );
    final String small = HttpDailyConnectionsService.excerpt(text, 200);
    expect(small, startsWith('a' * 130));
    expect(small, endsWith('z' * 70));
    expect(small.length, 200 + '\n[…]\n'.length);
  });

  test('sends selected sources and rejects fabricated links', () async {
    late Map<String, dynamic> request;
    MeasuredUsage? reportedUsage;
    final HttpDailyConnectionsService service = HttpDailyConnectionsService(
      recordUsage:
          ({
            required day,
            required openCaptures,
            required provider,
            required model,
            required usage,
          }) {
            reportedUsage = usage;
            expect(openCaptures, isFalse);
          },
      activeProfile: () => const ProviderProfile(
        id: 'p',
        name: 'Model',
        endpoint: 'https://example.com/v1/chat/completions',
        kind: ProfileKind.enrichment,
        model: 'test-model',
        bearerToken: 'token',
      ),
      client: MockClient((http.Request sent) async {
        request =
            jsonDecode(utf8.decode(sent.bodyBytes)) as Map<String, dynamic>;
        expect(sent.headers['Authorization'], 'Bearer token');
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'usage': <String, int>{
                'prompt_tokens': 120,
                'completion_tokens': 40,
              },
              'choices': <dynamic>[
                <String, dynamic>{
                  'message': <String, dynamic>{
                    'content': jsonEncode(<String, dynamic>{
                      'groups': <dynamic>[
                        <String, dynamic>{
                          'kind': 'complementary',
                          'title': 'Wyszukiwanie',
                          'explanation':
                              'Pierwsza uwaga i indeks uzupełniają się.',
                          'captureIds': <String>['one', 'two', 'one'],
                        },
                        <String, dynamic>{
                          'kind': 'sameTopic',
                          'title': 'Invalid',
                          'explanation': 'Only one real source.',
                          'captureIds': <String>['one', 'invented'],
                        },
                        <String, dynamic>{
                          'kind': 'appImprovement',
                          'title': 'Search',
                          'explanation': 'Improve the app search.',
                          'captureIds': <String>['one'],
                        },
                      ],
                    }),
                  },
                },
              ],
            }),
          ),
          200,
        );
      }),
    );

    final DailyConnectionsReport result = await service.review(
      ConnectionsScope.day(day),
      recordings,
    );
    final List<dynamic> sentCaptures =
        jsonDecode(
              ((request['messages'] as List<dynamic>).last
                      as Map<String, dynamic>)['content']
                  as String,
            )
            as List<dynamic>;
    expect(sentCaptures.map((dynamic c) => c['id']), <String>['one', 'two']);
    expect(
      (sentCaptures.first as Map<String, dynamic>)['text'],
      contains('Ulepszyć'),
    );
    expect(result.groups, hasLength(2));
    expect(result.groups.first.captureIds, <String>['one', 'two']);
    expect(result.groups.last.kind, ConnectionKind.appImprovement);
    expect(reportedUsage?.inputTokens, 120);
    expect(reportedUsage?.outputTokens, 40);
    service.close();
  });

  test('missing profile and malformed output fail clearly', () async {
    final HttpDailyConnectionsService disabled = HttpDailyConnectionsService(
      activeProfile: () => null,
    );
    await expectLater(
      disabled.review(ConnectionsScope.day(day), recordings),
      throwsA(isA<ConnectionsNotConfiguredException>()),
    );
    disabled.close();

    final HttpDailyConnectionsService malformed = HttpDailyConnectionsService(
      activeProfile: () => const ProviderProfile(
        id: 'p',
        name: 'Model',
        endpoint: 'https://example.com/chat',
        kind: ProfileKind.enrichment,
      ),
      client: MockClient((_) async => http.Response('not json', 200)),
    );
    await expectLater(
      malformed.review(ConnectionsScope.day(day), recordings),
      throwsA(isA<ConnectionsResponseException>()),
    );
    malformed.close();

    final HttpDailyConnectionsService inventedOnly =
        HttpDailyConnectionsService(
          activeProfile: () => const ProviderProfile(
            id: 'p',
            name: 'Model',
            endpoint: 'https://example.com/chat',
            kind: ProfileKind.enrichment,
          ),
          client: MockClient(
            (_) async => http.Response(
              jsonEncode(<String, dynamic>{
                'choices': <dynamic>[
                  <String, dynamic>{
                    'message': <String, dynamic>{
                      'content': jsonEncode(<String, dynamic>{
                        'groups': <dynamic>[
                          <String, dynamic>{
                            'kind': 'sameTopic',
                            'title': 'Invented',
                            'explanation': 'Unverifiable group',
                            'captureIds': <String>['one', 'invented'],
                          },
                        ],
                      }),
                    },
                  },
                ],
              }),
              200,
            ),
          ),
        );
    await expectLater(
      inventedOnly.review(ConnectionsScope.day(day), recordings),
      throwsA(isA<ConnectionsResponseException>()),
    );
    inventedOnly.close();
  });

  test(
    'public http is refused before the daily review sends a request',
    () async {
      int requests = 0;
      final HttpDailyConnectionsService service = HttpDailyConnectionsService(
        activeProfile: () => const ProviderProfile(
          id: 'p',
          name: 'Model',
          endpoint: 'http://api.example.com/v1/chat/completions',
          kind: ProfileKind.enrichment,
          bearerToken: 'token',
        ),
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        service.review(ConnectionsScope.day(day), recordings),
        throwsA(isA<InsecureConnectionsEndpointException>()),
      );
      expect(requests, 0);
      expect(
        const InsecureConnectionsEndpointException().toString(),
        contains('Use HTTPS'),
      );
      service.close();
    },
  );

  test('an unsupported endpoint scheme is refused before review', () async {
    int requests = 0;
    final HttpDailyConnectionsService service = HttpDailyConnectionsService(
      activeProfile: () => const ProviderProfile(
        id: 'p',
        name: 'Model',
        endpoint: 'ftp://api.example.com/v1/chat/completions',
        kind: ProfileKind.enrichment,
      ),
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );

    await expectLater(
      service.review(ConnectionsScope.day(day), recordings),
      throwsA(isA<InsecureConnectionsEndpointException>()),
    );
    expect(requests, 0);
    service.close();
  });
}
