import 'package:augustyniak_capture/features/switchboard/domain/context_facts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ContextFacts', () {
    // AC-5
    test('none is empty, and so is a default-constructed value', () {
      expect(ContextFacts.none.isEmpty, isTrue);
      expect(const ContextFacts().isEmpty, isTrue);
      expect(ContextFacts.none.priorities, isEmpty);
      expect(ContextFacts.none.tier, isNull);
      expect(ContextFacts.none.status, isNull);
    });

    // AC-5
    test('any priority, tier or status makes it non-empty', () {
      expect(const ContextFacts(priorities: <String>['a']).isEmpty, isFalse);
      expect(const ContextFacts(tier: 1).isEmpty, isFalse);
      expect(const ContextFacts(status: 'active').isEmpty, isFalse);
    });

    // AC-5
    test('toJson records the count, tier and status, never the items', () {
      final Map<String, dynamic> json = const ContextFacts(
        priorities: <String>['Ship the alpha', 'Renew the domain'],
        tier: 2,
        status: 'active',
      ).toJson();
      expect(json, <String, dynamic>{
        'priorityCount': 2,
        'tier': 2,
        'status': 'active',
      });
      expect(json.toString(), isNot(contains('Ship the alpha')));
    });

    // AC-5
    test('toJson omits null tier and status', () {
      final Map<String, dynamic> json = const ContextFacts(
        priorities: <String>['a'],
      ).toJson();
      expect(json, <String, dynamic>{'priorityCount': 1});
      expect(json.containsKey('tier'), isFalse);
      expect(json.containsKey('status'), isFalse);
    });
  });
}
