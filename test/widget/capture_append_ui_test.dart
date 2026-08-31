import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_editor.dart';

void main() {
  final DateTime at = DateTime.utc(2026, 8, 28, 10);

  Recording twoSegments() => Recording(
    id: 'abc',
    filePath: '/tmp/recordings/abc.m4a',
    createdAt: at,
    durationMs: 5000,
    sizeBytes: 2048,
    status: RecordingStatus.completed,
    type: CaptureType.audioRecording,
    transcript: 'first fragment\n\nsecond fragment',
    segments: <CaptureSegment>[
      CaptureSegment(
        index: 0,
        filePath: '/tmp/recordings/abc.m4a',
        type: CaptureType.audioRecording,
        createdAt: at,
        durationMs: 5000,
        sizeBytes: 2048,
        text: 'first fragment',
      ),
      CaptureSegment(
        index: 1,
        filePath: '/tmp/recordings/abc-1.txt',
        type: CaptureType.text,
        createdAt: at,
        sizeBytes: 12,
        text: 'second fragment',
      ),
    ],
  );

  Future<void> mount(
    WidgetTester tester,
    Recording recording, {
    VoidCallback? onAppendNote,
    VoidCallback? onAppendRecording,
    ValueChanged<CaptureType>? onAppendUpload,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RecordingEditor(
              recording: recording,
              revisions: const <RecordingRevision>[],
              tagSuggestions: const <String>[],
              onTitleChanged: (_) {},
              onTextChanged: (_) {},
              onCategoryChanged: (_) {},
              onTagsChanged: (_) {},
              onDone: () {},
              onAppendNote: onAppendNote,
              onAppendRecording: onAppendRecording,
              onAppendUpload: onAppendUpload,
            ),
          ),
        ),
      ),
    );
    // Never pumpAndSettle here: the editor holds text fields, which schedule
    // frames forever, so "no frames pending" is a state it never reaches.
    await tester.pump(const Duration(milliseconds: 250));
  }

  testWidgets('a multi-segment capture lists its fragments', (
    WidgetTester tester,
  ) async {
    await mount(tester, twoSegments(), onAppendNote: () {});

    expect(find.text('FRAGMENTS'), findsOneWidget);
    expect(find.textContaining('second fragment'), findsWidgets);
  });

  testWidgets('the note action fires once', (WidgetTester tester) async {
    int calls = 0;
    await mount(tester, twoSegments(), onAppendNote: () => calls++);

    await tester.ensureVisible(find.text('+ FRAGMENT'));
    await tester.pump();
    await tester.tap(find.text('+ FRAGMENT'));
    // The sheet slides in; a single pump lands mid-animation with its rows
    // still below the viewport, where a tap hits nothing.
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Scoped to the menu row: the editor's CATEGORY chips also spell NOTE,
    // and a bare text finder matches both.
    await tester.tap(find.widgetWithText(ListTile, 'NOTE'));
    // The sheet's own dismissal has to finish before its future resolves and
    // the callback runs, so this pumps the route out rather than settling —
    // the editor's text fields never stop scheduling frames.
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(calls, 1);
  });

  testWidgets('no append callbacks means no append control', (
    WidgetTester tester,
  ) async {
    await mount(tester, twoSegments());

    expect(find.text('+ FRAGMENT'), findsNothing);
  });
}
