import 'dart:io';

import 'package:augustyniak_capture/features/connections/domain/daily_connections.dart';
import 'package:augustyniak_capture/features/connections/presentation/daily_connections_dialog.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

class _ReviewService implements DailyConnectionsService {
  int runs = 0;
  ConnectionsScope? lastScope;
  List<String>? lastIds;

  @override
  Future<DailyConnectionsReport> review(
    ConnectionsScope scope,
    List<Recording> captures, {
    Map<String, String> projectNames = const <String, String>{},
  }) async {
    runs++;
    lastScope = scope;
    final List<Recording> selected = capturesInScope(captures, scope);
    lastIds = selected.map((Recording c) => c.id).toList();
    return DailyConnectionsReport(
      scope: scope,
      groups: <ConnectionGroup>[
        ConnectionGroup(
          kind: ConnectionKind.appImprovement,
          title: 'Improve search',
          explanation: 'The capture describes a missing search behavior.',
          captureIds: <String>[selected.first.id],
        ),
      ],
    );
  }
}

void main() {
  testWidgets('Queue exposes the manual review action', (
    WidgetTester tester,
  ) async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'connections_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final controller = await buildRecordingsController(directory);
    await tester.pumpWidget(
      hostTab(
        () => QueueTab(
          controller: controller,
          dailyConnectionsService: _ReviewService(),
        ),
      ),
    );
    await tester.tap(find.text('REVIEW CONNECTIONS'));
    await tester.pumpAndSettle();
    expect(find.text('Daily connections'), findsOneWidget);
    expect(find.text('0 text-ready captures on this day'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'REVIEW DAY'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('review shows source and opens the original capture', (
    WidgetTester tester,
  ) async {
    final Recording capture = Recording(
      id: 'capture-id',
      filePath: '/tmp/capture.txt',
      createdAt: DateTime.now(),
      durationMs: 0,
      status: RecordingStatus.completed,
      type: CaptureType.text,
      title: 'Search note',
      transcript: 'Search should find similar captures.',
    );
    final _ReviewService service = _ReviewService();
    Recording? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => DailyConnectionsDialog(
                  service: service,
                  captures: () => <Recording>[capture],
                  onOpenCapture: (Recording value) => opened = value,
                ),
              ),
              child: const Text('Open review'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open review'));
    await tester.pumpAndSettle();
    expect(find.text('1 text-ready capture on this day'), findsOneWidget);
    await tester.tap(find.text('REVIEW DAY'));
    await tester.pump();
    await tester.pump();
    expect(service.runs, 1);
    expect(find.text('Improve search'), findsOneWidget);
    await tester.ensureVisible(find.text('Search note'));
    await tester.tap(find.text('Search note'));
    await tester.pumpAndSettle();
    expect(opened, same(capture));
    expect(find.text('Daily connections'), findsNothing);
  });

  testWidgets('not-done scope counts and reviews every open capture', (
    WidgetTester tester,
  ) async {
    Recording text(String id, DateTime at, {bool done = false}) => Recording(
      id: id,
      filePath: '/tmp/$id.txt',
      createdAt: at,
      durationMs: 0,
      status: RecordingStatus.completed,
      type: CaptureType.text,
      title: id,
      transcript: 'Text of $id',
      isProcessedByUser: done,
    );
    final List<Recording> all = <Recording>[
      text('today-open', DateTime.now()),
      text('today-done', DateTime.now(), done: true),
      text('old-open', DateTime(2025, 3, 1)),
    ];
    final _ReviewService service = _ReviewService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => DailyConnectionsDialog(
                  service: service,
                  captures: () => all,
                  onOpenCapture: (_) {},
                ),
              ),
              child: const Text('Open review'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open review'));
    await tester.pumpAndSettle();
    expect(find.text('2 text-ready captures on this day'), findsOneWidget);
    await tester.tap(find.text('Not done yet'));
    await tester.pumpAndSettle();
    expect(find.text('2 text-ready captures not marked done'), findsOneWidget);
    expect(find.byIcon(Icons.calendar_today_outlined), findsNothing);
    await tester.tap(find.text('REVIEW OPEN'));
    await tester.pump();
    await tester.pump();
    expect(service.lastScope?.isOpen, isTrue);
    expect(service.lastIds, <String>['today-open', 'old-open']);
    expect(find.text('Improve search'), findsOneWidget);
    await tester.tap(find.text('One day'));
    await tester.pumpAndSettle();
    expect(find.text('Improve search'), findsNothing);
    expect(find.text('2 text-ready captures on this day'), findsOneWidget);
  });

  testWidgets('Queue opens a suggested source on a phone', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final Directory directory = Directory.systemTemp.createTempSync(
      'connections_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final File file = File('${directory.path}/capture-id.txt')
      ..writeAsStringSync('Search should find similar captures.');
    final Recording capture = Recording(
      id: 'capture-id',
      filePath: file.path,
      createdAt: DateTime.now(),
      durationMs: 0,
      status: RecordingStatus.completed,
      type: CaptureType.text,
      title: 'Search note',
      transcript: 'Search should find similar captures.',
    );
    final controller = await buildRecordingsController(
      directory,
      seed: <Recording>[capture],
    );
    await tester.pumpWidget(
      hostTab(
        () => QueueTab(
          controller: controller,
          dailyConnectionsService: _ReviewService(),
        ),
        listenable: controller,
      ),
    );
    await tester.tap(find.text('REVIEW CONNECTIONS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('REVIEW DAY'));
    await tester.pump();
    await tester.pump();
    final Finder source = find.widgetWithText(ActionChip, 'Search note');
    await tester.ensureVisible(source);
    await tester.tap(source);
    await tester.pumpAndSettle();
    expect(find.text('Daily connections'), findsNothing);
    expect(find.text('Search note'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
