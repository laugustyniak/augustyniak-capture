import 'dart:async';

import 'package:augustyniak_capture/features/auth/domain/auth_gateway.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_identity.dart';
import 'package:augustyniak_capture/features/auth/presentation/account_section.dart';
import 'package:augustyniak_capture/features/auth/presentation/auth_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

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
}

Future<void> changesClose(StreamController<AuthIdentity?> controller) =>
    controller.close();
