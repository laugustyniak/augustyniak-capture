import 'package:augustyniak_capture/features/settings/presentation/byoc_storage_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Sync builds its media store from the Supabase client alone
/// (`mediaStoreResolver` in `lib/app/app.dart`); the S3 settings are stored and
/// testable but never read by it (#415). The section must not claim otherwise.
void main() {
  testWidgets('the section says its settings are not used by sync yet', (
    WidgetTester tester,
  ) async {
    final controller = buildSettingsController();
    await controller.initialize();
    await tester.pumpWidget(
      hostTab(
        () => SingleChildScrollView(
          child: ByocStorageSection(controller: controller),
        ),
        listenable: controller,
      ),
    );
    await tester.pump();

    expect(find.textContaining('Not used by sync yet'), findsOneWidget);
    expect(find.textContaining('Supabase Storage'), findsOneWidget);
    expect(find.textContaining('Store media files on your own'), findsNothing);
  });
}
