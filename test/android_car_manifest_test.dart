import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the declarations Android Auto needs before it will list the app.
///
/// None of them is code the compiler checks: a missing `<uses name="template"/>`
/// or a wrong category still builds, installs and runs, and the app simply never
/// appears on the car display. The car app is also a second writer into the
/// capture inbox, so a manifest that loses RECORD_AUDIO would fail only in the
/// car. These assertions are what turn that into a red test.
void main() {
  String read(String path) => File(path).readAsStringSync();

  late String manifest;
  late String service;

  setUp(() {
    manifest = read('android/app/src/main/AndroidManifest.xml');
    final Match? match = RegExp(
      r'<service\b[^>]*CaptureCarAppService[\s\S]*?</service>',
    ).firstMatch(manifest);
    service = match?.group(0) ?? '';
  });

  test('the car app service is exported with the IOT category', () {
    expect(service, isNotEmpty, reason: 'CaptureCarAppService is declared');
    expect(service, contains('android:exported="true"'));
    expect(
      service,
      contains('<action android:name="androidx.car.app.CarAppService" />'),
    );
    expect(
      service,
      contains('<category android:name="androidx.car.app.category.IOT" />'),
    );
  });

  test('the service asks for car app API level 5', () {
    expect(
      manifest,
      contains(
        '<meta-data android:name="androidx.car.app.minCarApiLevel" '
        'android:value="5" />',
      ),
    );
  });

  test('the application points Android Auto at the app description', () {
    expect(
      manifest,
      contains(
        '<meta-data android:name="com.google.android.gms.car.application"\n'
        '            android:resource="@xml/automotive_app_desc" />',
      ),
    );
    expect(
      read('android/app/src/main/res/xml/automotive_app_desc.xml'),
      contains('<uses name="template" />'),
    );
  });

  test('the microphone permission is declared', () {
    expect(
      manifest,
      contains(
        '<uses-permission android:name="android.permission.RECORD_AUDIO" />',
      ),
    );
  });

  test('the car app library is a dependency', () {
    expect(
      read('android/app/build.gradle.kts'),
      contains('implementation("androidx.car.app:app:'),
    );
    // CarAudioRecord.create() throws at runtime without an implementation.
    expect(
      read('android/app/build.gradle.kts'),
      contains('implementation("androidx.car.app:app-projected:'),
    );
  });
}
