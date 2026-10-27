import 'dart:io';

import 'package:augustyniak_capture/features/enrichment/domain/embedding_service.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/related_captures.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_editor.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/recordings/presentation/related_section.dart';
import 'package:augustyniak_capture/features/settings/presentation/enrichment_context_section.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Bag of words over a fixed vocabulary — see `related_captures_test.dart`.
class _WordEmbeddings implements EmbeddingService {
  int calls = 0;

  @override
  String get model => 'words-1';

  @override
  Future<List<double>> embed(String text) async {
    calls++;
    final List<String> words = text.toLowerCase().split(RegExp(r'\W+'));
    return <double>[
      for (final String term in <String>['client', 'offer', 'garden'])
        words.where((String w) => w == term).length.toDouble(),
    ];
  }
}

void main() {
  late Directory appDir;

  setUp(() => appDir = Directory.systemTemp.createTempSync('related_ui_'));
  tearDown(() => appDir.deleteSync(recursive: true));

  Future<void> settleIo(WidgetTester tester) async {
    for (int i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  final List<Recording> library = <Recording>[
    makeRecording(
      id: 'a',
      title: 'Client call',
      transcript: 'call the client about the offer',
    ),
    makeRecording(
      id: 'b',
      title: 'Offer follow-up',
      transcript: 'send the client the offer',
    ),
    makeRecording(id: 'c', title: 'Garden', transcript: 'water the garden'),
  ];

  testWidgets('RelatedSection lists matches, flags a duplicate, opens one', (
    WidgetTester tester,
  ) async {
    final List<String> opened = <String>[];
    await tester.pumpWidget(
      hostTab(
        () => RelatedSection(
          entries: <RelatedEntry>[
            RelatedEntry(
              recording: library[1],
              match: const RelatedCapture(id: 'b', score: .93, duplicate: true),
            ),
            RelatedEntry(
              recording: library[2],
              match: const RelatedCapture(
                id: 'c',
                score: .61,
                duplicate: false,
              ),
            ),
          ],
          onOpen: (Recording r) => opened.add(r.id),
        ),
      ),
    );

    expect(find.text('Offer follow-up'), findsOneWidget);
    expect(find.text('93%'), findsOneWidget);
    expect(find.text(RelatedSection.duplicateLabel), findsOneWidget);
    await tester.tap(find.text('Garden'));
    expect(opened, <String>['c']);
  });

  group('in the queue', () {
    Future<RecordingsController> pumpIndexedQueue(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: library,
      );
      controller.embeddingService = _WordEmbeddings();
      await tester.runAsync(controller.buildIndex);
      await tester.pumpWidget(
        hostTab(() => QueueTab(controller: controller), listenable: controller),
      );
      await tester.pump();
      return controller;
    }

    testWidgets('cards carry the related count, only where there is one', (
      WidgetTester tester,
    ) async {
      await pumpIndexedQueue(tester);
      // a and b point at each other; c points at nothing.
      expect(find.text('≈ 1'), findsNWidgets(2));
      expect(find.textContaining('≈ '), findsNWidgets(2));
    });

    testWidgets('the editor lists the related capture and jumps to it', (
      WidgetTester tester,
    ) async {
      await pumpIndexedQueue(tester);
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Client call'),
            matching: find.byType(RecordingCard),
          ),
          matching: find.byIcon(Icons.edit_outlined),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey<String>('editor-a')), findsOneWidget);

      final Finder link = find.descendant(
        of: find.byType(RelatedSection),
        matching: find.text('Offer follow-up'),
      );
      await tester.ensureVisible(link);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(link);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const ValueKey<String>('editor-b')), findsOneWidget);
      expect(find.byType(RecordingEditor), findsOneWidget);
    });
  });

  testWidgets('Config names the model and builds the index', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final SettingsController settings = buildSettingsController();
    await settings.initialize();
    final RecordingsController recordings = await buildRecordingsController(
      appDir,
      seed: library,
    );
    await tester.pumpWidget(
      hostTab(
        () => EnrichmentContextSection(
          controller: settings,
          recordings: recordings,
        ),
        listenable: settings,
      ),
    );
    await tester.pump();
    expect(find.textContaining('Off. Name an embedding model'), findsOneWidget);

    final Finder field = find.widgetWithText(
      TextField,
      'text-embedding-3-small · nomic-embed-text',
    );
    await tester.ensureVisible(field);
    await tester.enterText(field, 'words-1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleIo(tester);
    expect(settings.embeddingModel, 'words-1');

    // The shell installs the service from settings; here it is done by hand.
    final _WordEmbeddings embeddings = _WordEmbeddings();
    recordings.embeddingService = embeddings;
    await tester.pump();
    expect(find.text('BUILD INDEX 3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('build-index')));
    await settleIo(tester);

    expect(embeddings.calls, 3);
    expect(find.textContaining('Every capture is indexed'), findsOneWidget);
  });
}
