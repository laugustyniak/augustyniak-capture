import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> row(String kind) => <String, dynamic>{
    'recordingId': 'abc',
    'at': DateTime(2026, 11, 27, 9).toIso8601String(),
    'kind': kind,
    'type': 'text',
  };

  test('an agent closure is a known kind and round-trips', () {
    // AC-5
    expect(ClosureKind.fromName('agent')?.name, 'agent');
    final ClosureEvent? back = ClosureEvent.fromJson(row('agent'));
    expect(back, isNotNull);
    expect(back!.kind.name, 'agent');
    expect(back.toJson()['kind'], 'agent');
  });

  test('an unknown kind still degrades to a dropped row', () {
    // AC-7
    expect(ClosureKind.fromName('agentt'), isNull);
    expect(ClosureEvent.fromJson(row('agentt')), isNull);
  });

  test('legacy kinds still read back', () {
    // AC-7
    for (final String name in <String>['review', 'route', 'handoff']) {
      expect(ClosureEvent.fromJson(row(name))?.kind.name, name);
    }
  });
}
