import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/commitment.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/commitments_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Recording _capture(String id, String title, List<Commitment> commitments) =>
    Recording(
      id: id,
      filePath: '/tmp/$id.txt',
      createdAt: DateTime(2026, 11, 4),
      durationMs: 0,
      status: RecordingStatus.completed,
      type: CaptureType.text,
      title: title,
      commitments: commitments,
    );

void main() {
  testWidgets('lists open commitments by due date and acts on them', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<List<Recording>> captures =
        ValueNotifier<List<Recording>>(<Recording>[
          _capture('a', 'Client call', <Commitment>[
            Commitment(text: 'Send the offer', due: DateTime(2026, 11, 20)),
            const Commitment(text: 'Old', state: CommitmentState.done),
          ]),
          _capture('b', 'Standup', <Commitment>[
            Commitment(text: 'Fix the build', due: DateTime(2026, 11, 6)),
          ]),
        ]);
    final List<String> changes = <String>[];
    final List<String> exported = <String>[];
    final List<String> opened = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommitmentsDialog(
            listenable: captures,
            captures: () => captures.value,
            onSetState: (String id, Commitment c, CommitmentState s) async {
              changes.add('$id:${c.key}:${s.name}');
              captures.value = <Recording>[
                for (final Recording r in captures.value)
                  r.id == id
                      ? r.copyWith(
                          commitments: <Commitment>[
                            for (final Commitment x in r.commitments!)
                              x.key == c.key ? x.copyWith(state: s) : x,
                          ],
                        )
                      : r,
              ];
            },
            onExport: (Recording r, Commitment c) async => exported.add(c.text),
            onOpenCapture: (Recording r) => opened.add(r.id),
          ),
        ),
      ),
    );

    expect(find.text('Old'), findsNothing);
    final double first = tester.getTopLeft(find.text('Fix the build')).dy;
    final double second = tester.getTopLeft(find.text('Send the offer')).dy;
    expect(first, lessThan(second));

    await tester.tap(find.byTooltip('Export Fix the build'));
    await tester.pump();
    expect(exported, <String>['Fix the build']);

    await tester.tap(find.byTooltip('Mark Fix the build done'));
    await tester.pump();
    expect(changes, <String>['b:fix the build:done']);
    expect(find.text('Fix the build'), findsNothing);

    await tester.tap(find.byTooltip('Dismiss Send the offer'));
    await tester.pump();
    expect(changes.last, 'a:send the offer:dismissed');
    expect(find.text('No open commitments.'), findsOneWidget);
  });

  testWidgets('tapping a commitment opens its capture', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<List<Recording>> captures =
        ValueNotifier<List<Recording>>(<Recording>[
          _capture('a', 'Client call', <Commitment>[
            const Commitment(text: 'Send the offer'),
          ]),
        ]);
    final List<String> opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommitmentsDialog(
            listenable: captures,
            captures: () => captures.value,
            onSetState: (_, _, _) async {},
            onExport: (_, _) async {},
            onOpenCapture: (Recording r) => opened.add(r.id),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Client call'));
    await tester.pump();
    expect(opened, <String>['a']);
  });
}
