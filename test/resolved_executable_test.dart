import 'package:augustyniak_capture/core/process/resolved_executable.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an absolute path is returned untouched', () async {
    expect(await resolveExecutable('/no/such/ffmpeg'), '/no/such/ffmpeg');
  });

  test('a name that exists nowhere falls back to the bare name', () async {
    expect(
      await resolveExecutable('augustyniak-no-such-binary'),
      'augustyniak-no-such-binary',
    );
  });

  test('a bare name resolves to an absolute path when it exists', () async {
    // `ls` lives in /bin on every supported desktop, so this does not depend
    // on Homebrew being installed.
    final String resolved = await resolveExecutable('ls');
    expect(resolved, startsWith('/'));
    expect(resolved, endsWith('/ls'));
  });
}
