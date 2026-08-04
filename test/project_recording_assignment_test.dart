import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';

import 'support/harness.dart';

void main() {
  test('new captures inherit the active project id', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'audivoa-project-capture-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final RecordingsController controller = await buildRecordingsController(
      directory,
    );

    controller.activeProjectId = 'project-a';
    await controller.addTextNote('project context');
    await controller.waitForProcessing();

    expect(controller.recordings.single.projectId, 'project-a');
  });
}
