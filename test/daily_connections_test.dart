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

Recording capture(String id, DateTime day, String? text) => Recording(
  id: id,
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

  test('sends selected sources and rejects fabricated links', () async {
    late Map<String, dynamic> request;
    MeasuredUsage? reportedUsage;
    final HttpDailyConnectionsService service = HttpDailyConnectionsService(
      recordUsage:
          ({required day, required provider, required model, required usage}) {
            reportedUsage = usage;
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

    final DailyConnectionsReport result = await service.review(day, recordings);
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
      disabled.review(day, recordings),
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
      malformed.review(day, recordings),
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
      inventedOnly.review(day, recordings),
      throwsA(isA<ConnectionsResponseException>()),
    );
    inventedOnly.close();
  });
}
