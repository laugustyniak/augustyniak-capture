import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/data/command_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/suggested_route.dart';
import 'package:augustyniak_capture/features/switchboard/data/rule_table_capture_policy.dart';
import 'package:augustyniak_capture/features/switchboard/domain/capture_facts.dart';
import 'package:augustyniak_capture/features/switchboard/domain/capture_policy.dart';
import 'package:augustyniak_capture/features/switchboard/domain/context_facts.dart';
import 'package:augustyniak_capture/features/switchboard/domain/decision.dart';
import 'package:flutter_test/flutter_test.dart';

const SuggestedRouteKind _command = SuggestedRouteKind.command;
const SuggestedRouteKind _agent = SuggestedRouteKind.agent;
const SuggestedRouteKind _file = SuggestedRouteKind.file;
const SuggestedRouteKind _none = SuggestedRouteKind.none;

CaptureFacts _facts({
  CaptureCategory? category = CaptureCategory.agentTask,
  List<SuggestedRouteKind> available = const <SuggestedRouteKind>[],
  SuggestedRouteKind? model,
  String? projectId = 'p',
}) => CaptureFacts(
  category: category,
  projectId: projectId,
  availableRouteKinds: available,
  modelRoute: model,
);

final RuleTableCapturePolicy _policy = RuleTableCapturePolicy(
  commandCategories: <CaptureCategory>{CaptureCategory.agentTask},
);

void main() {
  group('DisabledCapturePolicy', () {
    test('decides nothing, whatever the facts', () {
      const CapturePolicy policy = DisabledCapturePolicy();
      expect(
        policy.decide(_facts(available: <SuggestedRouteKind>[_command])),
        isNull,
      );
      expect(policy.decide(_facts(category: null)), isNull);
    });
  });

  group('RuleTableCapturePolicy rules', () {
    test('R10: an agent task whose project resolves to Command', () {
      final Decision? d = _policy.decide(
        _facts(available: <SuggestedRouteKind>[_command, _agent]),
      );
      expect(d!.ruleId, 'R10');
      expect(d.kind, _command);
    });

    test('R20: an agent task with an agent but no Command', () {
      final Decision? d = _policy.decide(
        _facts(available: <SuggestedRouteKind>[_file, _agent]),
      );
      expect(d!.ruleId, 'R20');
      expect(d.kind, _agent);
    });

    test('R30: an agent task that can only be filed', () {
      final Decision? d = _policy.decide(
        _facts(available: <SuggestedRouteKind>[_file]),
      );
      expect(d!.ruleId, 'R30');
      expect(d.kind, _file);
    });

    test('R80: a non-agent capture takes the model\'s answered kind', () {
      final Decision? d = _policy.decide(
        _facts(
          category: CaptureCategory.idea,
          available: <SuggestedRouteKind>[_file, _agent],
          model: _file,
        ),
      );
      expect(d!.ruleId, 'R80');
      expect(d.kind, _file);
    });

    test('R80: an explicit none from the model is kept as none', () {
      final Decision? d = _policy.decide(
        _facts(
          category: CaptureCategory.note,
          available: <SuggestedRouteKind>[_file],
          model: _none,
        ),
      );
      expect(d!.ruleId, 'R80');
      expect(d.kind, _none);
    });

    test(
      'R80 is skipped when the model named a kind that is not available',
      () {
        final Decision? d = _policy.decide(
          _facts(
            category: CaptureCategory.note,
            available: <SuggestedRouteKind>[_file],
            model: _agent,
          ),
        );
        expect(d!.ruleId, 'R90');
        expect(d.kind, _none);
      },
    );

    test('R90: nothing matched, so none', () {
      for (final CaptureCategory category in <CaptureCategory>[
        CaptureCategory.note,
        CaptureCategory.agentTask,
      ]) {
        final Decision? d = _policy.decide(_facts(category: category));
        expect(d!.ruleId, 'R90', reason: '$category');
        expect(d.kind, _none);
      }
    });

    test('first match wins: R10 beats a model that said file', () {
      final Decision? d = _policy.decide(
        _facts(available: <SuggestedRouteKind>[_command], model: _file),
      );
      expect(d!.ruleId, 'R10');
      expect(d.kind, _command);
    });

    test('first match wins: R10 beats a model that said none', () {
      final Decision? d = _policy.decide(
        _facts(available: <SuggestedRouteKind>[_command, _agent], model: _none),
      );
      expect(d!.ruleId, 'R10');
      expect(d.kind, _command);
    });

    test('a category outside commandCategories never fires R10', () {
      final Decision? d = _policy.decide(
        _facts(
          category: CaptureCategory.task,
          available: <SuggestedRouteKind>[_command],
        ),
      );
      expect(d!.ruleId, isNot('R10'));
    });
  });

  group('RuleTableCapturePolicy contract', () {
    test('null category (enrichment never ran) yields no decision', () {
      expect(
        _policy.decide(
          _facts(category: null, available: <SuggestedRouteKind>[_command]),
        ),
        isNull,
      );
    });

    test('the same facts give the same ruleId and facts', () {
      final CaptureFacts facts = _facts(
        available: <SuggestedRouteKind>[_file, _agent],
        model: _agent,
      );
      final Decision a = _policy.decide(facts)!;
      final Decision b = _policy.decide(facts)!;
      expect(a.ruleId, b.ruleId);
      expect(a.kind, b.kind);
      expect(a.reason, b.reason);
      expect(a.facts, b.facts);
      expect(a.facts, facts);
    });

    test('every reason is English text within the suggestion limit', () {
      final List<CaptureFacts> all = <CaptureFacts>[
        _facts(available: <SuggestedRouteKind>[_command]),
        _facts(available: <SuggestedRouteKind>[_agent]),
        _facts(available: <SuggestedRouteKind>[_file]),
        _facts(
          category: CaptureCategory.idea,
          available: <SuggestedRouteKind>[_file],
          model: _file,
        ),
        _facts(category: CaptureCategory.idea, model: _none),
        _facts(category: CaptureCategory.idea),
      ];
      for (final CaptureFacts facts in all) {
        final String? reason = _policy.decide(facts)?.reason;
        expect(reason, isNotNull);
        expect(reason!.trim(), isNotEmpty);
        expect(reason.length, lessThanOrEqualTo(SuggestedRoute.maxReasonChars));
        // ASCII-only is a cheap proxy for "no Polish diacritics slipped in".
        expect(reason, matches(RegExp(r'^[\x20-\x7E·—]+$')));
      }
    });
  });

  group('ContextFacts', () {
    const ContextFacts withNote = ContextFacts(
      priorities: <String>['Ship the alpha', 'Renew the domain'],
      tier: 1,
      status: 'active',
    );

    // AC-5
    test('Disabled still decides nothing when given a context', () {
      const CapturePolicy policy = DisabledCapturePolicy();
      expect(
        policy.decide(
          _facts(available: <SuggestedRouteKind>[_command]),
          withNote,
        ),
        isNull,
      );
    });

    // AC-5
    test('no rule reads the priorities: ruleId, kind and reason are unchanged',
        () {
      final List<CaptureFacts> all = <CaptureFacts>[
        _facts(available: <SuggestedRouteKind>[_command, _agent]),
        _facts(available: <SuggestedRouteKind>[_file, _agent]),
        _facts(available: <SuggestedRouteKind>[_file]),
        _facts(
          category: CaptureCategory.idea,
          available: <SuggestedRouteKind>[_file],
          model: _file,
        ),
        _facts(category: CaptureCategory.idea, model: _none),
        _facts(category: CaptureCategory.idea),
        _facts(category: null),
      ];
      for (final CaptureFacts facts in all) {
        final Decision? without = _policy.decide(facts);
        final Decision? with_ = _policy.decide(facts, withNote);
        expect(with_?.ruleId, without?.ruleId);
        expect(with_?.kind, without?.kind);
        expect(with_?.reason, without?.reason);
        expect(with_?.facts, without?.facts);
      }
    });

    // AC-5
    test('the decision carries the context it was given, none by default', () {
      final CaptureFacts facts = _facts(
        available: <SuggestedRouteKind>[_command],
      );
      expect(_policy.decide(facts, withNote)!.context, same(withNote));
      expect(_policy.decide(facts)!.context.isEmpty, isTrue);
      expect(_policy.decide(facts)!.context, ContextFacts.none);
    });
  });

  group('parity with ProjectCaptureRouter', () {
    test('R10 fires exactly when resolvedKind is command', () {
      final List<Set<CaptureCategory>> categorySets = <Set<CaptureCategory>>[
        const <CaptureCategory>{CaptureCategory.agentTask},
        const <CaptureCategory>{
          CaptureCategory.agentTask,
          CaptureCategory.idea,
        },
        const <CaptureCategory>{},
      ];
      var checked = 0;
      var commandSeen = 0;
      for (final Set<CaptureCategory> commandCategories in categorySets) {
        for (final CaptureCategory? category in <CaptureCategory?>[
          null,
          ...CaptureCategory.values,
        ]) {
          for (final bool bound in <bool>[true, false]) {
            for (final RouteKind? fallbackKind in <RouteKind?>[
              RouteKind.file,
              null,
            ]) {
              final ProjectCaptureRouter router = ProjectCaptureRouter(
                command: _FixedRouter(bound ? RouteKind.command : null),
                fallback: _FixedRouter(fallbackKind),
                commandCategories: commandCategories,
              );
              final RouteKind? resolved = router.resolvedKind(
                RoutedCapture(
                  id: 'c',
                  projectId: 'p',
                  title: 't',
                  body: 'b',
                  capturedAt: DateTime.utc(2026),
                  type: CaptureType.text,
                  category: category,
                ),
              );
              // The controller's availableRouteKinds, reduced to the router.
              final List<SuggestedRouteKind> available = <SuggestedRouteKind>[
                if (resolved == RouteKind.command)
                  _command
                else if (resolved == RouteKind.file)
                  _file,
                _agent,
              ];
              final Decision? d =
                  RuleTableCapturePolicy(
                    commandCategories: commandCategories,
                  ).decide(
                    CaptureFacts(
                      category: category,
                      projectId: 'p',
                      availableRouteKinds: available,
                      modelRoute: null,
                    ),
                  );
              expect(
                d?.ruleId == 'R10',
                resolved == RouteKind.command,
                reason:
                    '$category bound=$bound fallback=$fallbackKind '
                    'categories=$commandCategories',
              );
              checked++;
              if (resolved == RouteKind.command) commandSeen++;
            }
          }
        }
      }
      expect(checked, 3 * 8 * 2 * 2);
      expect(commandSeen, greaterThan(0), reason: 'the matrix must hit R10');
    });
  });
}

class _FixedRouter implements CaptureRouter {
  _FixedRouter(this.kind);
  final RouteKind? kind;
  @override
  bool canRoute(String? projectId) => kind != null;
  @override
  RouteKind? resolvedKind(RoutedCapture capture) => kind;
  @override
  Future<RouteRecord> route(RoutedCapture capture) async =>
      throw UnimplementedError();
}
