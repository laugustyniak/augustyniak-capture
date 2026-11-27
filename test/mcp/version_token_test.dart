import 'dart:convert';

import 'package:augustyniak_capture/features/mcp/data/sqlite_capture_source.dart';
import 'package:augustyniak_capture/features/mcp/domain/capture_tools.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/domain/suggested_route.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mcp_call.dart';
import 'mcp_fixture.dart';

/// The version the app computes for a row it loaded: it holds
/// `fromJson(payload)` after a restart and hashes `jsonEncode(toJson())`.
/// Spelled out here, not imported, so the test is an independent oracle.
String appVersion(String storedPayload) {
  final Recording loaded = Recording.fromJson(
    jsonDecode(storedPayload) as Map<String, dynamic>,
  );
  return sha256.convert(utf8.encode(jsonEncode(loaded.toJson()))).toString();
}

void main() {
  late McpFixture fx;

  setUp(() => fx = McpFixture());
  tearDown(() => fx.dispose());

  Future<String> serverVersion(String id) async {
    final CaptureTools tools = CaptureTools(
      SqliteCaptureSource(
        dbPath: fx.dbPath,
        recordingsDir: fx.recordingsDir.path,
      ),
    );
    final Map<String, dynamic> page =
        (await callBody(tools, 'next_open_captures', <String, dynamic>{}))
            as Map<String, dynamic>;
    return (page['captures'] as List).cast<Map<String, dynamic>>().singleWhere(
          (Map<String, dynamic> c) => c['id'] == id,
        )['version']
        as String;
  }

  Recording realistic() =>
      rec(
        'real',
        at: DateTime.utc(2026, 5, 1, 8, 30),
        title: 'Zażółć gęślą jaźń',
        summary: 'naïve café ☕ 日本語',
        transcript: 'Zażółć gęślą jaźń — "quoted" \\ back/slash 😀',
        tags: const <String>['ł', 'ü'],
        routes: <RouteRecord>[
          RouteRecord(
            at: DateTime.utc(2026, 5, 2),
            kind: RouteKind.command,
            target: 'host',
            decision: const RouteDecision(ruleId: 'R10', reason: 'bound'),
          ),
        ],
      ).copyWith(
        suggestedRoute: const SuggestedRoute(
          kind: SuggestedRouteKind.command,
          reason: 'bound',
          ruleId: 'R10',
        ),
      );

  test('payload with an unknown key: version is the app re-encoding', () async {
    // AC-4
    final Map<String, dynamic> json = realistic().toJson();
    final String stored = jsonEncode(<String, dynamic>{
      ...json,
      'fieldFromANewerBuild': <String, dynamic>{'x': 1},
    });
    fx.insert(realistic(), payload: stored);
    expect(await serverVersion('real'), appVersion(stored));
  });

  test(
    'payload with escaped unicode and padding: same canonical token',
    () async {
      // AC-4
      final String stored =
          '${jsonEncode(realistic().toJson()).replaceAll('ł', r'ł')}  ';
      expect(stored, contains(r'ł'));
      fx.insert(realistic(), payload: stored);
      expect(await serverVersion('real'), appVersion(stored));
    },
  );

  test('payload with reordered keys: same canonical token', () async {
    // AC-4
    final Map<String, dynamic> json = realistic().toJson();
    final Map<String, dynamic> reordered = <String, dynamic>{
      for (final String k in json.keys.toList().reversed) k: json[k],
    };
    final String stored = jsonEncode(reordered);
    fx.insert(realistic(), payload: stored);
    expect(await serverVersion('real'), appVersion(stored));
  });

  test(
    'legacy minimal payload (no optional keys) gets the app token',
    () async {
      // AC-4
      final String stored = jsonEncode(<String, dynamic>{
        'id': 'legacy',
        'filePath': '/x/legacy.m4a',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'durationMs': 10,
        'status': 'completed',
      });
      fx.insert(rec('legacy'), payload: stored);
      expect(await serverVersion('legacy'), appVersion(stored));
    },
  );

  test('an already canonical payload keeps the same token', () async {
    // AC-4
    final String stored = jsonEncode(realistic().toJson());
    fx.insert(realistic(), payload: stored);
    expect(await serverVersion('real'), appVersion(stored));
    // And for an app that never restarted, which hashes the in-memory row: a
    // fromJson/toJson round trip that is not idempotent would show up here.
    expect(
      await serverVersion('real'),
      sha256.convert(utf8.encode(stored)).toString(),
    );
  });
}
