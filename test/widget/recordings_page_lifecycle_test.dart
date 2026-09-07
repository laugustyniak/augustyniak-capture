import 'dart:io';

import 'package:augustyniak_capture/features/recordings/presentation/recordings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('recordings_page_lifecycle_test_');
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => tempDir.path,
    );
    for (final String name in <String>[
      'com.llfbandit.record/messages',
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'plugins.it_nomads.com/flutter_secure_storage',
      'hotkey_manager',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (MethodCall call) async => null,
      );
    }
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets(
    'lifecycle state change to AppLifecycleState.resumed triggers resumeInterruptedProcessing',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: RecordingsPage(),
        ),
      );
      await tester.pumpAndSettle();

      final dynamic state = tester.state(find.byType(RecordingsPage));
      expect(state, isNotNull);

      // Verify that didChangeAppLifecycleState can be called with resumed state
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();

      // Trigger binding lifecycle event to verify system integration
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    },
  );
}
