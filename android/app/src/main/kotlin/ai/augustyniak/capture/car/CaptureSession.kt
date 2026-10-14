package ai.augustyniak.capture.car

import android.content.Intent
import androidx.car.app.Screen
import androidx.car.app.Session

class CaptureSession : Session() {
    override fun onCreateScreen(intent: Intent): Screen = CaptureScreen(carContext)
}
