import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/recordings/data/decision_drainer.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/agent_decision.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/agent_decision_support.dart';

/// `DecisionDrainer` is created by #474 in
/// `recordings/data/decision_drainer.dart`, shaped like `InboxDrainer`.
/// Constructor (assumed): named `directory`, `apply`, `logSink`, where `apply`
/// is `Future<DecisionOutcome> Function(AgentDecision)`. `drain()` returns an
/// int: 0 when a drain is already running or the directory is missing. A
/// refused file moves to `rejected/<name>` with `<uuid>.reason.txt` beside it.
class _Crash implements Exception {}

void main() {
  const String idA = '123e4567-e89b-42d3-a456-426614174000';
  const String idB = '223e4567-e89b-42d3-a456-426614174000';
  late Directory root;
  late Directory decisions;
  late CollectingLog logs;
  late List<AgentDecision> applied;

  setUp(() {
    root = Directory.systemTemp.createTempSync('decision_drainer_');
    seedDirectory = root;
    decisions = Directory(p.join(root.path, 'decisions'))..createSync();
    logs = CollectingLog();
    applied = <AgentDecision>[];
  });
  tearDown(() => root.deleteSync(recursive: true));

  String payload(String decisionId, {String captureId = 'cap-1'}) => jsonEncode(
    makeDecision(captureId, version: 'v', decisionId: decisionId).toJson(),
  );

  File put(String name, String content, {int ageSeconds = 0}) {
    final File f = File(p.join(decisions.path, name))
      ..writeAsStringSync(content);
    f.setLastModifiedSync(
      DateTime.now().subtract(Duration(seconds: ageSeconds)),
    );
    return f;
  }

  DecisionDrainer drainer(
    Future<DecisionOutcome> Function(AgentDecision) apply,
  ) => DecisionDrainer(directory: decisions, apply: apply, logSink: logs);

  Future<DecisionOutcome> record(
    AgentDecision d,
    DecisionOutcome outcome,
  ) async {
    applied.add(d);
    return outcome;
  }

  bool exists(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  String rejectedPath(String name) => p.join(decisions.path, 'rejected', name);

  test('a missing directory is a no-op', () async {
    // AC-5
    decisions.deleteSync();
    expect(
      await drainer(
        (AgentDecision d) => record(d, const DecisionOutcome.applied()),
      ).drain(),
      0,
    );
  });

  test('applied: the file is deleted only after apply returned', () async {
    // AC-5
    final File f = put('$idA.json', payload(idA));
    late bool existedDuringApply;
    final int n = await drainer((AgentDecision d) async {
      existedDuringApply = f.existsSync();
      applied.add(d);
      return const DecisionOutcome.applied();
    }).drain();
    expect(n, 1);
    expect(existedDuringApply, isTrue);
    expect(applied.single.decisionId, idA);
    expect(applied.single.captureId, 'cap-1');
    expect(f.existsSync(), isFalse);
  });

  test('alreadyClosed: the file is deleted', () async {
    // AC-5
    final File f = put('$idA.json', payload(idA));
    await drainer(
      (AgentDecision d) => record(d, const DecisionOutcome.alreadyClosed()),
    ).drain();
    expect(applied, hasLength(1));
    expect(f.existsSync(), isFalse);
    expect(Directory(p.join(decisions.path, 'rejected')).existsSync(), isFalse);
  });

  test(
    'rejected: moved to rejected/ with a reason file and a log entry',
    () async {
      // AC-5
      final File f = put('$idA.json', payload(idA));
      await drainer(
        (AgentDecision d) =>
            record(d, const DecisionOutcome.rejected('stale version')),
      ).drain();
      expect(f.existsSync(), isFalse);
      expect(File(rejectedPath('$idA.json')).existsSync(), isTrue);
      expect(
        File(rejectedPath('$idA.reason.txt')).readAsStringSync(),
        contains('stale version'),
      );
      expect(logs.mentions('stale version'), isTrue);
    },
  );

  test('apply throws: the file stays for the next pass', () async {
    // AC-6
    final File f = put('$idA.json', payload(idA));
    await drainer(
      (AgentDecision d) async => throw StateError('disk full'),
    ).drain();
    expect(f.existsSync(), isTrue);
    expect(Directory(p.join(decisions.path, 'rejected')).existsSync(), isFalse);
    // ...and it is applied when the failure clears.
    await drainer(
      (AgentDecision d) => record(d, const DecisionOutcome.applied()),
    ).drain();
    expect(applied, hasLength(1));
    expect(f.existsSync(), isFalse);
  });

  test('oldest-modified file is applied first', () async {
    // AC-5
    put('$idA.json', payload(idA, captureId: 'new'), ageSeconds: 10);
    put('$idB.json', payload(idB, captureId: 'old'), ageSeconds: 100);
    await drainer(
      (AgentDecision d) => record(d, const DecisionOutcome.applied()),
    ).drain();
    expect(applied.map((AgentDecision d) => d.captureId), <String>[
      'old',
      'new',
    ]);
  });

  test('.tmp files and other extensions are left alone', () async {
    // AC-2
    final File tmp = put('$idA.json.tmp', '{half');
    final File other = put('$idB.txt', 'x');
    await drainer(
      (AgentDecision d) => record(d, const DecisionOutcome.applied()),
    ).drain();
    expect(applied, isEmpty);
    expect(tmp.existsSync(), isTrue);
    expect(other.existsSync(), isTrue);
  });

  test('a file in rejected/ is never read again', () async {
    // AC-5
    final File old = File(rejectedPath('$idA.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(payload(idA));
    await drainer(
      (AgentDecision d) => record(d, const DecisionOutcome.applied()),
    ).drain();
    expect(applied, isEmpty);
    expect(old.existsSync(), isTrue);
  });

  group('hostile input never reaches apply', () {
    Future<void> expectRefused(String name) async {
      await drainer(
        (AgentDecision d) => record(d, const DecisionOutcome.applied()),
      ).drain();
      expect(applied, isEmpty, reason: name);
      expect(
        exists(p.join(decisions.path, name)),
        isFalse,
        reason: '$name must leave the watched directory',
      );
      expect(exists(rejectedPath(name)), isTrue, reason: name);
    }

    test('a non-uuid file name', () async {
      // AC-5
      put('notes.json', payload(idA));
      await expectRefused('notes.json');
    });

    test('a decisionId that is not the file name', () async {
      // AC-5
      put('$idA.json', payload(idB));
      await expectRefused('$idA.json');
    });

    test('an oversize file', () async {
      // AC-5
      put('$idA.json', payload(idA, captureId: 'c') + ' ' * 70000);
      await expectRefused('$idA.json');
    });

    test('unparseable JSON', () async {
      // AC-5
      put('$idA.json', '{"decisionId": ');
      await expectRefused('$idA.json');
    });

    test('a structurally invalid decision', () async {
      // AC-5
      put('$idA.json', payload(idA, captureId: '../../etc'));
      await expectRefused('$idA.json');
    });

    test('a symlinked file, whose target is not touched', () async {
      // AC-5
      final File target = File(p.join(root.path, 'victim.json'))
        ..writeAsStringSync(payload(idA));
      Link(p.join(decisions.path, '$idA.json')).createSync(target.path);
      await expectRefused('$idA.json');
      expect(target.existsSync(), isTrue);
      expect(target.readAsStringSync(), payload(idA));
    }, skip: Platform.isWindows ? 'no symlinks' : false);
  });

  test('a concurrent drain returns 0 and does not apply twice', () async {
    // AC-6
    put('$idA.json', payload(idA));
    final Completer<void> gate = Completer<void>();
    final DecisionDrainer d = drainer((AgentDecision x) async {
      applied.add(x);
      await gate.future;
      return const DecisionOutcome.applied();
    });
    final Future<int> first = d.drain();
    while (applied.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(await d.drain(), 0);
    gate.complete();
    expect(await first, 1);
    expect(applied, hasLength(1));
  });

  test(
    'process death between apply and delete re-applies idempotently',
    () async {
      // AC-6
      final Directory data = Directory(p.join(root.path, 'data'))..createSync();
      final CollectingClosureLog closures = CollectingClosureLog();
      RecordingsRepository repo() =>
          RecordingsRepository(directoryProvider: () async => data);

      await repo().saveAll(<Recording>[seedRecording('r1')]);
      final RecordingsController first = await buildController(
        repo(),
        closures: closures,
      );
      final AgentDecision d = makeDecision(
        'r1',
        version: versionOf(first, 'r1'),
        decisionId: idA,
      );
      final File file = put('$idA.json', jsonEncode(d.toJson()));

      // The apply lands, then the process dies before the file is deleted.
      await drainer((AgentDecision x) async {
        await first.applyAgentDecision(x);
        throw _Crash();
      }).drain();
      expect(file.existsSync(), isTrue, reason: 'delete never ran');
      // `first` is simply abandoned, as a killed process would; the harness
      // disposes it at teardown.

      // A fresh process: new repository, controller and drainer, same disk.
      final RecordingsController second = await buildController(
        repo(),
        closures: closures,
      );
      await second.recoverOrphans();
      final int n = await drainer(second.applyAgentDecision).drain();

      expect(n, 1);
      expect(file.existsSync(), isFalse);
      expect(exists(rejectedPath('$idA.json')), isFalse);
      final List<Recording> onDisk = await repo().loadAll();
      expect(onDisk.single.isProcessedByUser, isTrue);
      expect(onDisk.single.routes, hasLength(1));
      expect(closures.appended, hasLength(1));
    },
  );

  test(
    'a real controller with a failing write keeps the file, then applies it',
    () async {
      // AC-6
      final SwitchableRepository repo = SwitchableRepository(
        root,
        seed: <Recording>[seedRecording('r1')],
      );
      final RecordingsController c = await buildController(repo);
      final AgentDecision d = makeDecision(
        'r1',
        version: versionOf(c, 'r1'),
        decisionId: idA,
      );
      final File file = put('$idA.json', jsonEncode(d.toJson()));

      repo.failWrites = true;
      await drainer(c.applyAgentDecision).drain();
      expect(file.existsSync(), isTrue);
      expect(byId(c, 'r1').isProcessedByUser, isFalse);

      repo.failWrites = false;
      await drainer(c.applyAgentDecision).drain();
      expect(file.existsSync(), isFalse);
      expect(byId(c, 'r1').routes, hasLength(1));
    },
  );
}
