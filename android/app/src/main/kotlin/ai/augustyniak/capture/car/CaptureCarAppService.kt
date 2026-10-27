package ai.augustyniak.capture.car

import android.content.pm.ApplicationInfo
import androidx.car.app.CarAppService
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator

/**
 * Entry point Android Auto binds to. No Flutter engine and no MainActivity: the
 * car app only records into the inbox the Dart side drains later.
 */
class CaptureCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator {
        // Any host is fine for the Desktop Head Unit on a debug build; a release
        // build only talks to the hosts Google publishes in the sample list.
        val debuggable = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        return if (debuggable) {
            HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        } else {
            HostValidator.Builder(this)
                .addAllowedHosts(androidx.car.app.R.array.hosts_allowlist_sample)
                .build()
        }
    }

    override fun onCreateSession(): Session = CaptureSession()
}
