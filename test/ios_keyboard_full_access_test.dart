import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the iOS keyboard extension to the least privilege it can run with.
///
/// `RequestsOpenAccess` is the Full Access switch: it lets a keyboard reach the
/// network and the App Group container, and iOS warns the user that such a
/// keyboard "could transmit anything you type". The keyboard here inserts
/// recent clipboard entries and nothing else, and the file it reads from the
/// shared container is one the host no longer writes (#312). The key was
/// `true` with no reason anyone could name; this test makes turning it back on
/// a documented decision — see `docs/platform-setup.md`.
void main() {
  group('iOS keyboard extension', () {
    test('does not request Full Access', () {
      final String plist = File(
        'ios/CaptureKeyboard/Info.plist',
      ).readAsStringSync();
      final RegExpMatch? match = RegExp(
        r'<key>RequestsOpenAccess</key>\s*<(true|false)/>',
      ).firstMatch(plist);
      expect(match, isNotNull, reason: 'the key must be declared explicitly');
      expect(match!.group(1), 'false');
    });

    // The keyboard has nothing to show until the host publishes its clipboard
    // history into the App Group again, and a keyboard that is installed and
    // shows nothing is worse than none (#343). The target stays in the project
    // so restoring it is one revert; the Runner must not embed or build it.
    test('is not embedded in the Runner app', () {
      final String project = File(
        'ios/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();
      expect(project, isNot(contains('CaptureKeyboard.appex in Embed')));
      expect(project, isNot(contains('remoteInfo = CaptureKeyboard;')));
    });

    test('never touches the network or the system pasteboard', () {
      final String swift = File(
        'ios/CaptureKeyboard/CaptureKeyboardViewController.swift',
      ).readAsStringSync();
      for (final String symbol in <String>[
        'URLSession',
        'URLRequest',
        'NSURLConnection',
        'UIPasteboard',
        'NWConnection',
      ]) {
        expect(swift, isNot(contains(symbol)), reason: symbol);
      }
    });
  });
}
