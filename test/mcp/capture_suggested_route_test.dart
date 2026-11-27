import 'package:augustyniak_capture/features/mcp/data/sqlite_capture_source.dart';
import 'package:augustyniak_capture/features/mcp/domain/capture_tools.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/suggested_route.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mcp_call.dart';
import 'mcp_fixture.dart';

void main() {
  late McpFixture fx;

  setUp(() {
    fx = McpFixture();
    fx.insertProject(projectA);
    fx.insert(
      rec(
        'with',
        at: DateTime.utc(2026, 4, 1),
        title: 'Has a suggestion',
        transcript: 'needle',
        projectId: 'p-1',
      ).copyWith(
        suggestedRoute: const SuggestedRoute(
          kind: SuggestedRouteKind.command,
          reason: 'bound to Command',
          ruleId: 'R10',
        ),
      ),
    );
    fx.insert(
      rec(
        'bare',
        at: DateTime.utc(2026, 4, 2),
        title: 'Dismissed, no rule, no reason',
        transcript: 'needle',
        projectId: 'p-1',
      ).copyWith(
        suggestedRoute: const SuggestedRoute(
          kind: SuggestedRouteKind.file,
          auto: false,
        ),
      ),
    );
    fx.insert(
      rec(
        'none',
        at: DateTime.utc(2026, 4, 3),
        title: 'No suggestion',
        transcript: 'needle',
        projectId: 'p-1',
      ),
    );
  });
  tearDown(() => fx.dispose());

  CaptureTools tools() => CaptureTools(
    SqliteCaptureSource(
      dbPath: fx.dbPath,
      recordingsDir: fx.recordingsDir.path,
    ),
  );

  Map<String, dynamic> byId(Object? list, String id) => (list as List)
      .cast<Map<String, dynamic>>()
      .singleWhere((Map<String, dynamic> c) => c['id'] == id);

  void expectShapes(
    Map<String, dynamic> with_,
    Map<String, dynamic> bare,
    Map<String, dynamic> none,
  ) {
    expect(with_['suggestedRoute'], <String, dynamic>{
      'kind': 'command',
      'ruleId': 'R10',
      'reason': 'bound to Command',
      'auto': true,
    });
    // Absent keys are absent, never null.
    expect(bare['suggestedRoute'], <String, dynamic>{
      'kind': 'file',
      'auto': false,
    });
    expect(none.containsKey('suggestedRoute'), isFalse);
  }

  test('get_capture returns suggestedRoute with ruleId', () async {
    // AC-1
    Future<Map<String, dynamic>> get(String id) async =>
        (await callBody(tools(), 'get_capture', <String, dynamic>{'id': id}))
            as Map<String, dynamic>;
    expectShapes(await get('with'), await get('bare'), await get('none'));
  });

  test('search_captures returns suggestedRoute', () async {
    // AC-1
    final Object? list = await callBody(
      tools(),
      'search_captures',
      <String, dynamic>{'query': 'needle'},
    );
    expectShapes(byId(list, 'with'), byId(list, 'bare'), byId(list, 'none'));
  });

  test('list_project_captures returns suggestedRoute', () async {
    // AC-1
    final Object? list = await callBody(
      tools(),
      'list_project_captures',
      <String, dynamic>{'project': 'p-1'},
    );
    expectShapes(byId(list, 'with'), byId(list, 'bare'), byId(list, 'none'));
  });

  test('next_open_captures returns suggestedRoute', () async {
    // AC-1
    final Map<String, dynamic> page =
        (await callBody(tools(), 'next_open_captures', <String, dynamic>{}))
            as Map<String, dynamic>;
    final Object? list = page['captures'];
    expectShapes(byId(list, 'with'), byId(list, 'bare'), byId(list, 'none'));
  });

  test('status is untouched by the suggestion', () async {
    // AC-1
    final Map<String, dynamic> c =
        (await callBody(tools(), 'get_capture', <String, dynamic>{
              'id': 'with',
            }))
            as Map<String, dynamic>;
    expect(c['status'], RecordingStatus.completed.name);
  });
}
