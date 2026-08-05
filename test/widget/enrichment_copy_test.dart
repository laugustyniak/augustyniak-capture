import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/card_parts.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// What the enrichment pass produced is as liftable as the transcript it was
/// derived from — a summary goes into a standup note, a tag line into a vault.
///
/// Like `copy_button_test.dart` this one has to reach a platform channel: what
/// lands on the clipboard is the entire contract, and it is invisible from the
/// widget tree. Everything else about these rows stays in the pure-Dart suites.
void main() {
  late List<MethodCall> platformCalls;

  setUp(() {
    platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          platformCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  String? copiedText() {
    for (final MethodCall call in platformCalls) {
      if (call.method == 'Clipboard.setData') {
        return (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
    }
    return null;
  }

  /// Finds the one copy button that carries this tooltip. Addressing it by the
  /// button's own field rather than by a semantics label keeps the finder off
  /// `debugSemantics`, which only exists for what is painted — and a tag row
  /// sits low enough on a card to be below the fold on a short surface.
  Finder copyButton(String tooltip) => find.byWidgetPredicate(
    (Widget widget) => widget is CopyButton && widget.tooltip == tooltip,
  );

  Future<void> tapCopy(WidgetTester tester, Finder button) async {
    await tester.tap(button);
    await tester.pump();
    // Drain the "copied" feedback timer so the test ends with none pending.
    await tester.pump(const Duration(milliseconds: 1700));
  }

  final Recording enriched = makeRecording(
    id: 'enriched',
    title: 'Client call',
    transcript: 'zadzwonić do klienta w piątek i potwierdzić zakres',
    summary:
        'The client wants the scope confirmed before Friday, and asked for a '
        'written estimate covering the second phase as well — which is more '
        'than the two lines a card can render.',
    tags: <String>['client', 'estimate', 'q3'],
  );

  group('the card', () {
    Future<void> pumpCard(WidgetTester tester) async {
      await tester.pumpWidget(
        hostTab(
          () => RecordingCard(
            recording: enriched,
            isPlaying: false,
            isEnriching: false,
            onTogglePlay: () {},
            onOpen: () {},
            onRetry: () {},
            onEnrich: () {},
            onEdit: () {},
            onToggleProcessed: () {},
            onRoute: () {},
            onHandoff: () {},
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('copies the whole summary, not the two rendered lines', (
      WidgetTester tester,
    ) async {
      await pumpCard(tester);
      await tapCopy(tester, copyButton('Copy summary'));

      expect(copiedText(), enriched.summary);
    });

    testWidgets('copies tags as a tag line, hashes included', (
      WidgetTester tester,
    ) async {
      await pumpCard(tester);
      await tapCopy(tester, copyButton('Copy tags'));

      // The hash is what makes the pasted line a tag line in the notes tools
      // the vault mirror already writes into — dropping it would paste
      // something that merely looks like the chips on screen.
      expect(copiedText(), '#client #estimate #q3');
    });

    testWidgets('an un-enriched card offers neither button', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        hostTab(
          () => RecordingCard(
            recording: makeRecording(id: 'plain', transcript: 'jakiś tekst'),
            isPlaying: false,
            isEnriching: false,
            onTogglePlay: () {},
            onOpen: () {},
            onRetry: () {},
            onEnrich: () {},
            onEdit: () {},
            onToggleProcessed: () {},
            onRoute: () {},
            onHandoff: () {},
          ),
        ),
      );
      await tester.pump();

      expect(copyButton('Copy summary'), findsNothing);
      expect(copyButton('Copy tags'), findsNothing);
      // The transcript's own button is untouched by any of this.
      expect(copyButton('Copy text'), findsOneWidget);
    });
  });

  group('the compact row', () {
    Future<void> pumpRow(WidgetTester tester, {required bool expanded}) async {
      await tester.pumpWidget(
        hostTab(
          () => RecordingRow(
            recording: enriched,
            expanded: expanded,
            focused: false,
            isPlaying: false,
            isEnriching: false,
            canRoute: false,
            canHandoff: false,
            onTap: () {},
            onTogglePlay: () {},
            onOpen: () {},
            onRetry: () {},
            onEnrich: () {},
            onEdit: () {},
            onRoute: () {},
            onHandoff: () {},
            onToggleProcessed: () {},
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('carries both buttons once expanded', (
      WidgetTester tester,
    ) async {
      await pumpRow(tester, expanded: true);

      await tapCopy(tester, copyButton('Copy summary'));
      expect(copiedText(), enriched.summary);

      platformCalls.clear();
      await tapCopy(tester, copyButton('Copy tags'));
      expect(copiedText(), tagsClipboardText(enriched.tags));
    });

    testWidgets('a collapsed row keeps them hidden with the rest of the body', (
      WidgetTester tester,
    ) async {
      await pumpRow(tester, expanded: false);

      expect(copyButton('Copy summary'), findsNothing);
      expect(copyButton('Copy tags'), findsNothing);
    });
  });
}
