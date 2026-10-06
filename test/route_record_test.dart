import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an assistant route round-trips through JSON', () {
    final RouteRecord record = RouteRecord(
      at: DateTime.utc(2026, 10, 6, 12),
      kind: RouteKind.assistant,
      target: 'ChatGPT · web',
    );

    final RouteRecord? back = RouteRecord.fromJson(record.toJson());

    expect(back, isNotNull);
    expect(back!.kind, RouteKind.assistant);
    expect(back.target, 'ChatGPT · web');
    expect(record.toJson()['kind'], 'assistant');
  });

  test('legacy kinds still read back unchanged', () {
    for (final String name in <String>['file', 'agent', 'command']) {
      final RouteRecord? back = RouteRecord.fromJson(<String, dynamic>{
        'at': '2026-10-06T12:00:00.000Z',
        'kind': name,
        'target': 'x',
      });
      expect(back?.kind.name, name);
    }
  });

  test('an unknown kind is still dropped rather than guessed', () {
    expect(RouteKind.fromName('teleport'), isNull);
    expect(
      RouteRecord.fromJson(<String, dynamic>{
        'at': '2026-10-06T12:00:00.000Z',
        'kind': 'teleport',
        'target': 'x',
      }),
      isNull,
    );
  });
}
