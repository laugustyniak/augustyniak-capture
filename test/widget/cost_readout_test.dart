import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:augustyniak_capture/features/costs/presentation/cost_section.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/card_parts.dart';
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
}
