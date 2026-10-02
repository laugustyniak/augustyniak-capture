import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/clipboard/data/clipboard_capture_reader.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/presentation/paste_capture_shortcut.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('ai.augustyniak.capture/clipboard');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('file URL wins over advertised text and keeps its media type', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'getPasteFile') return '/tmp/photo.png';
      fail('Image lookup must not run for a file URL');
    });
    final pasted = await const ClipboardCaptureReader().read();
    expect(pasted.file?.path, '/tmp/photo.png');
    expect(pasted.type, CaptureType.image);
    expect(pasted.text, isNull);
  });

  test('unknown file extension becomes an attachment capture', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'getPasteFile') return '/tmp/report.pdf';
      return null;
    });
    final pasted = await const ClipboardCaptureReader().read();
    expect(pasted.file?.path, '/tmp/report.pdf');
    expect(pasted.type, CaptureType.file);
    expect(pasted.temporary, isFalse);
  });

  test('copied audio file is classified as upload, not microphone recording', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'getPasteFile') return '/tmp/speech.m4a';
      return null;
    });
    expect((await const ClipboardCaptureReader().read()).type,
        CaptureType.audioUpload);
  });

  test('native image bytes are imported as PNG', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'getPasteImage') return '/tmp/pasted-image';
      return null;
    });
    final pasted = await const ClipboardCaptureReader().read();
    expect(pasted.file?.path, '/tmp/pasted-image');
    expect(pasted.type, CaptureType.image);
    expect(pasted.mimeType, 'image/png');
  });

  test('plain text works without a native clipboard channel', () async {
    messenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'Clipboard.getData') return <String, Object>{'text': 'note'};
      return null;
    });
    final pasted = await const ClipboardCaptureReader().read();
    expect(pasted.file, isNull);
    expect(pasted.text, 'note');
  });

  testWidgets('paste shortcut leaves a focused text field to handle paste',
      (WidgetTester tester) async {
    int captures = 0;
    final TextEditingController text = TextEditingController();
    addTearDown(text.dispose);
    messenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'Clipboard.getData') return <String, Object>{'text': 'pasted'};
      return null;
    });
    await tester.pumpWidget(MaterialApp(
      home: PasteCaptureShortcut(
        onPaste: () => captures++,
        child: Scaffold(body: TextField(controller: text)),
      ),
    ));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(captures, 0);
    expect(text.text, 'pasted');
  });

  testWidgets('paste shortcut captures Ctrl+V outside editors',
      (WidgetTester tester) async {
    int captures = 0;
    await tester.pumpWidget(MaterialApp(
      home: PasteCaptureShortcut(
        onPaste: () => captures++,
        child: const Scaffold(body: Center(child: Text('Queue'))),
      ),
    ));
    await tester.tap(find.text('Queue'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(captures, 1);
  });
}
