import 'package:augustyniak_capture/core/sync/sync_pairing_payload.dart';
import 'package:augustyniak_capture/features/settings/presentation/sync_pairing_confirmation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Applying a pairing code repoints where every future capture is uploaded, so
/// it is the one settings change this app takes from *whatever was in front of
/// the camera*. The scanner used to write the credentials and pull from the
/// address before the sheet had drawn a single word about it.
void main() {
  const SyncPairingPayload payload = SyncPairingPayload(
    tursoDbUrl: 'libsql://db-stranger.turso.io',
    tursoAuthToken: 'token-abc',
    r2Endpoint: 'https://account.r2.cloudflarestorage.com',
    r2Bucket: 'captures',
    r2AccessKeyId: 'key-id',
    r2SecretAccessKey: 'key-secret',
  );

  Future<bool?> show(WidgetTester tester) async {
    bool? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                answer = await confirmSyncPairing(context, payload);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('names the host that is about to receive every capture', (
    WidgetTester tester,
  ) async {
    await show(tester);

    // A token says nothing to a reader; a hostname is the whole decision.
    expect(find.textContaining('db-stranger.turso.io'), findsOneWidget);
  });

  testWidgets('says that media storage is being configured as well', (
    WidgetTester tester,
  ) async {
    await show(tester);

    // The R2 secret access key rides the same code, and uploads go elsewhere
    // than the index does.
    expect(find.textContaining('captures'), findsOneWidget);
  });

  testWidgets('cancelling answers no, and is the default', (
    WidgetTester tester,
  ) async {
    await show(tester);

    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();

    // The sheet is torn down without an answer on a back-gesture too, which
    // `confirmSyncPairing` has to read as a refusal rather than as consent.
    expect(find.text('CANCEL'), findsNothing);
  });

  testWidgets('confirming is what answers yes', (WidgetTester tester) async {
    bool? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                answer = await confirmSyncPairing(context, payload);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('PAIR'));
    await tester.pumpAndSettle();

    expect(answer, isTrue);
  });

  testWidgets('a refusal answers no', (WidgetTester tester) async {
    bool? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                answer = await confirmSyncPairing(context, payload);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();

    expect(answer, isFalse);
  });
}
