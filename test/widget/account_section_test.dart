import 'dart:async';

import 'package:augustyniak_capture/features/auth/domain/auth_gateway.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_identity.dart';
import 'package:augustyniak_capture/features/auth/presentation/account_section.dart';
import 'package:augustyniak_capture/features/auth/presentation/auth_controller.dart';
import 'package:augustyniak_capture/features/auth/data/secure_auth_storage.dart';
import 'package:augustyniak_capture/features/sync/data/e2ee_service.dart';
import 'package:augustyniak_capture/features/sync/domain/e2ee_cipher.dart';
import 'package:augustyniak_capture/features/sync/presentation/e2ee_passphrase_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import '../sync/fake_e2ee_settings_store.dart';

class _FakeAuthGateway implements AuthGateway {
  _FakeAuthGateway({this.currentIdentity});

  @override
  AuthIdentity? currentIdentity;

  final StreamController<AuthIdentity?> changes =
      StreamController<AuthIdentity?>.broadcast();
  int signInCalls = 0;
  int signOutCalls = 0;

  @override
  Stream<AuthIdentity?> get identityChanges => changes.stream;

  @override
  Future<bool> signInWithGoogle() async {
    signInCalls += 1;
    return true;
  }

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
  }
}

class _InMemorySecureStore implements SecureValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  testWidgets('signed-out account can start Google login', (
    WidgetTester tester,
  ) async {
    final _FakeAuthGateway gateway = _FakeAuthGateway();
    final AuthController controller = AuthController(gateway)..initialize();
    addTearDown(controller.dispose);
    addTearDown(() => changesClose(gateway.changes));

    await tester.pumpWidget(
      hostTab(() => AccountSection(controller: controller)),
    );

    expect(find.text('CONTINUE WITH GOOGLE'), findsOneWidget);
    await tester.tap(find.text('CONTINUE WITH GOOGLE'));
    await tester.pump();
    expect(gateway.signInCalls, 1);
  });

  testWidgets('signed-in account shows its durable owner id and can sign out', (
    WidgetTester tester,
  ) async {
    final _FakeAuthGateway gateway = _FakeAuthGateway(
      currentIdentity: const AuthIdentity(
        id: '3c79b2e4-9988-4e5a-9b88-25159c65fdd2',
        email: 'owner@example.com',
        displayName: 'Owner',
      ),
    );
    final AuthController controller = AuthController(gateway)..initialize();
    addTearDown(controller.dispose);
    addTearDown(() => changesClose(gateway.changes));

    await tester.pumpWidget(
      hostTab(() => AccountSection(controller: controller)),
    );

    expect(find.text('owner@example.com'), findsOneWidget);
    expect(find.text('3c79b2e4-9988-4e5a-9b88-25159c65fdd2'), findsOneWidget);
    await tester.tap(find.text('SIGN OUT'));
    await tester.pump();
    expect(gateway.signOutCalls, 1);
  });

  testWidgets('the card names the encryption state and offers set-up, lock and forget (#317)', (
    WidgetTester tester,
  ) async {
    const String ownerId = '3c79b2e4-9988-4e5a-9b88-25159c65fdd2';
    final _FakeAuthGateway gateway = _FakeAuthGateway(
      currentIdentity: const AuthIdentity(
        id: ownerId,
        email: 'owner@example.com',
        displayName: 'Owner',
      ),
    );
    final AuthController controller = AuthController(gateway)..initialize();
    addTearDown(controller.dispose);
    addTearDown(() => changesClose(gateway.changes));
    final _InMemorySecureStore keyring = _InMemorySecureStore();
    final FakeE2eeSettingsStore settings = FakeE2eeSettingsStore();
    final E2eeService e2ee = E2eeService(
      secureStore: keyring,
      kdf: E2eeKeyDerivation(iterations: 1000),
      settings: settings,
    );
    addTearDown(e2ee.dispose);

    await tester.pumpWidget(
      hostTab(() => AccountSection(controller: controller, e2ee: e2ee)),
    );
    await e2ee.followIdentity(ownerId);
    await tester.pump();

    expect(find.text('NOT SET UP'), findsOneWidget);
    await tester.tap(find.text('SET UP ENCRYPTION'));
    await tester.pump();
    expect(find.text(E2eePassphraseDialog.lossWarning), findsOneWidget);
    await tester.tap(find.text('CANCEL'));
    await tester.pump();
    expect(find.text(E2eePassphraseDialog.lossWarning), findsNothing);

    await e2ee.enroll('correct horse');
    await tester.pump();
    expect(find.text('END-TO-END, UNLOCKED'), findsOneWidget);
    expect(find.text('LOCK'), findsOneWidget);
    expect(find.text('FORGET KEY'), findsOneWidget);

    await tester.tap(find.text('LOCK'));
    await tester.pump();
    expect(find.text('LOCKED ON THIS DEVICE'), findsOneWidget);
    expect(find.text('UNLOCK'), findsOneWidget);
    expect(keyring.values, isNotEmpty);

    // FORGET KEY asks first; cancelling keeps the key.
    await tester.tap(find.text('FORGET KEY'));
    await tester.pump();
    expect(find.textContaining('removed from this device only'), findsOneWidget);
    await tester.tap(find.text('CANCEL'));
    await tester.pump();
    expect(keyring.values, isNotEmpty);

    await tester.tap(find.text('FORGET KEY'));
    await tester.pump();
    await tester.tap(find.text('FORGET KEY').last);
    await tester.pump();
    await tester.pump();
    expect(keyring.values, isEmpty);
    expect(find.text('LOCKED ON THIS DEVICE'), findsOneWidget);
    expect(settings.rows[ownerId], isNotNull); // the server row is never deleted
  });

  testWidgets('missing Supabase config leaves local capture available', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AccountSection())),
    );

    expect(find.text('CLOUD ACCOUNT UNAVAILABLE'), findsOneWidget);
    expect(
      find.textContaining('Local capture remains available'),
      findsOneWidget,
    );
  });

  testWidgets('an unconfigured card says why the config was refused', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountSection(configIssue: 'x')),
      ),
    );
    expect(find.text('Refused: x'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AccountSection())),
    );
    expect(find.textContaining('Refused'), findsNothing);
  });
}

Future<void> changesClose(StreamController<AuthIdentity?> controller) =>
    controller.close();
