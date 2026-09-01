package ai.augustyniak.capture;

import androidx.test.rule.ActivityTestRule;
import dev.flutter.plugins.integration_test.FlutterTestRunner;
import org.junit.Rule;
import org.junit.runner.RunWith;

/// Lets `adb shell am instrument` run the Dart integration tests against an
/// app that is **already installed**.
///
/// `flutter test -d <device>` reinstalls the app on every run and the install
/// clears its data directory, so any artifact staged beforehand — a speech
/// model, a capture to transcribe — is gone before the first line of the test
/// runs. Decoupling install from run is the only way those tests can see a file
/// that had to be put there from the host.
@RunWith(FlutterTestRunner.class)
public class MainActivityTest {
  @Rule
  public ActivityTestRule<MainActivity> rule =
      new ActivityTestRule<>(MainActivity.class, true, false);
}
