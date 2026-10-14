import 'package:augustyniak_capture/features/recordings/domain/capture_instruction.dart';
import 'package:augustyniak_capture/features/recordings/domain/cleanup_proposal.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/capture_text_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const String _raw = 'so uh add a retry to the OCR';
const String _instruction = 'Add a retry to the OCR step.';

Recording _with({CaptureInstruction? instruction}) => Recording.fromJson(
  makeRecording(id: 'a', transcript: _raw).toJson()
    ..addAll(<String, dynamic>{
      if (instruction != null) 'instruction': instruction.toJson(),
    }),
);

void main() {
  Future<void> pumpTabs(
    WidgetTester tester,
    Recording recording, {
    VoidCallback? onRewrite,
  }) => tester.pumpWidget(
    hostTab(
      () => CaptureTextTabs(
        recording: recording,
        raw: const Text(_raw),
        instructionBody: (String text) => Text(text),
        onRewrite: onRewrite,
      ),
    ),
  );

  testWidgets('opens on the instruction, and RAW shows the transcript', (
    WidgetTester tester,
  ) async {
    await pumpTabs(
      tester,
      _with(
        instruction: CaptureInstruction(
          text: _instruction,
          source: CleanupProposal.fingerprint(_raw),
        ),
      ),
    );

    expect(find.text(_instruction), findsOneWidget);
    expect(find.text(_raw), findsNothing);

    await tester.tap(find.text(CaptureTextTabs.rawLabel));
    await tester.pump();

    expect(find.text(_raw), findsOneWidget);
    expect(find.text(_instruction), findsNothing);
  });

  testWidgets('without an instruction it opens on RAW and offers REWRITE', (
    WidgetTester tester,
  ) async {
    int rewrites = 0;
    await pumpTabs(tester, _with(), onRewrite: () => rewrites++);

    expect(find.text(_raw), findsOneWidget);
    await tester.tap(find.text(CaptureTextTabs.rewriteLabel));
    expect(rewrites, 1);
  });

  testWidgets('nothing to tab between renders the raw text alone', (
    WidgetTester tester,
  ) async {
    await pumpTabs(tester, _with());

    expect(find.text(_raw), findsOneWidget);
    expect(find.text(CaptureTextTabs.instructionLabel), findsNothing);
  });
}
