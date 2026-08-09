import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:augustyniak_capture/features/costs/presentation/cost_section.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/recordings/presentation/card_parts.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Recording _recording() => Recording(
  id: 'cap-1',
  filePath: '/tmp/cap-1.m4a',
  createdAt: DateTime.utc(2026, 8, 9),
  durationMs: 90000,
  sizeBytes: 7130316,
  status: RecordingStatus.completed,
  type: CaptureType.audioRecording,
);

void main() {
  testWidgets('the verification line prints the cost when there is one', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(VerificationLine(recording: _recording(), costUsd: 0.0021)),
    );
    await tester.pump();

    expect(find.textContaining('file verified'), findsOneWidget);
    expect(find.textContaining('\$0.0021'), findsOneWidget);
  });

  testWidgets('a capture with no events prints a dash, not a zero', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(VerificationLine(recording: _recording(), costUsd: null)),
    );
    await tester.pump();

    expect(find.textContaining('cost —'), findsOneWidget);
    expect(find.textContaining('\$0.0000'), findsNothing);
  });

  testWidgets('the cost section lists one row per event', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SingleChildScrollView(
          child: CostSection(
            sizeBytes: 7130316,
            storagePrice: StoragePrice.defaults,
            events: <UsageEvent>[
              UsageEvent(
                id: 'e1',
                captureId: 'cap-1',
                stage: UsageStage.transcription,
                provider: 'api.openai.com',
                model: 'gpt-transcribe',
                at: DateTime.utc(2026, 8, 9),
                audioSeconds: 90,
                costUsd: 0.00675,
              ),
              UsageEvent(
                id: 'e2',
                captureId: 'cap-1',
                stage: UsageStage.enrichment,
                provider: 'api.openai.com',
                model: 'gpt-5.6-luna',
                at: DateTime.utc(2026, 8, 9),
                inputTokens: 1200,
                outputTokens: 90,
                costUsd: 0.000348,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('TRANSCRIPTION'), findsOneWidget);
    expect(find.textContaining('ENRICHMENT'), findsOneWidget);
    expect(find.textContaining('gpt-transcribe'), findsOneWidget);
    expect(find.textContaining('1 200 in'), findsOneWidget);
  });

  testWidgets('an unpriced event says why rather than showing zero', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        CostSection(
          sizeBytes: 0,
          storagePrice: StoragePrice.defaults,
          events: <UsageEvent>[
            UsageEvent(
              id: 'e1',
              captureId: 'cap-1',
              stage: UsageStage.transcription,
              provider: 'api.openai.com',
              model: 'gpt-transcribe',
              at: DateTime.utc(2026, 8, 9),
              unpricedReason: UnpricedReason.noQuantity,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('unknown duration'), findsOneWidget);
    expect(find.textContaining('\$0.0000'), findsNothing);
  });

  // Fix round 3: RecordingEditor._totalCostUsd was covered so far only by
  // "all priced" (the case above, via VerificationLine directly) and "all
  // absent" (the empty-list default). Neither exercises the rule that
  // actually matters — that a *mix* of priced and unpriced events must not
  // sum to a partial figure — which is the same rule
  // `UsageRepository.totalsByCapture()` enforces in SQL for the card. This is
  // that test for the editor's side of the same agreement.
  testWidgets(
    'the editor total reads cost — for a mix of priced and unpriced events, '
    'not a partial sum',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          RecordingEditor(
            recording: _recording(),
            revisions: const <RecordingRevision>[],
            tagSuggestions: const <String>[],
            onTitleChanged: (String _) {},
            onTextChanged: (String _) {},
            onCategoryChanged: (CaptureCategory? _) {},
            onTagsChanged: (List<String> _) {},
            onDone: () {},
            usageEvents: <UsageEvent>[
              // Priced — same figures fix round 1 used for the card's
              // real-total test, so a reader can compare the two directly.
              UsageEvent(
                id: 'e1',
                captureId: 'cap-1',
                stage: UsageStage.transcription,
                provider: 'api.openai.com',
                model: 'gpt-transcribe',
                at: DateTime.utc(2026, 8, 9),
                audioSeconds: 90,
                costUsd: 0.0045,
              ),
              UsageEvent(
                id: 'e2',
                captureId: 'cap-1',
                stage: UsageStage.enrichment,
                provider: 'api.openai.com',
                model: 'gpt-5.6-luna',
                at: DateTime.utc(2026, 8, 9),
                inputTokens: 500,
                outputTokens: 50,
                costUsd: 0.00021,
              ),
              // Unpriced — this is what makes the capture's total unknown.
              UsageEvent(
                id: 'e3',
                captureId: 'cap-1',
                stage: UsageStage.ocr,
                provider: 'api.openai.com',
                model: 'gpt-5.6-luna',
                at: DateTime.utc(2026, 8, 9),
                unpricedReason: UnpricedReason.noRate,
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      // The verification line — the one place a *total* is printed — reads
      // cost —, not the sum of the two priced events (0.0045 + 0.00021 =
      // 0.00471, which would render as $0.0047). $0.0045 and $0.0002 are
      // deliberately not asserted absent: CostSection's own per-event
      // breakdown legitimately prints each priced event's own amount
      // directly underneath, and only the fabricated $0.0047 total would
      // reveal a regression here.
      expect(find.textContaining('cost —'), findsOneWidget);
      expect(find.textContaining('\$0.0047'), findsNothing);
    },
  );
}
