import 'package:augustyniak_capture/app/version_footer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets('missing bundle metadata does not show an invented version', (
    WidgetTester tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Capture',
      packageName: 'ai.augustyniak.capture',
      version: '',
      buildNumber: '',
      buildSignature: '',
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: VersionFooter())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Installed version unavailable'), findsOneWidget);
  });

  for (final String version in <String>['0.2.0', '0.3.1']) {
    testWidgets(
      'shows installed $version metadata without checking the network',
      (WidgetTester tester) async {
        PackageInfo.setMockInitialValues(
          appName: 'Capture',
          packageName: 'ai.augustyniak.capture',
          version: version,
          buildNumber: '42',
          buildSignature: '',
        );
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: VersionFooter())),
        );
        await tester.pumpAndSettle();

        expect(find.text('Capture $version (build 42)'), findsOneWidget);
        expect(find.text('Latest release & changelog'), findsOneWidget);
        expect(find.textContaining('up to date'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
