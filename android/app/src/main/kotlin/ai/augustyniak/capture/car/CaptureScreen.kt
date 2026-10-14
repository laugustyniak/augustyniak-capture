package ai.augustyniak.capture.car

import android.Manifest
import android.content.pm.PackageManager
import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.model.Action
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Template
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import java.io.File

/**
 * One screen, one decision: REC while idle, STOP while recording. "Saved" is
 * shown only when [CarCaptureFiles.finalize] reported a verified file.
 */
class CaptureScreen(carContext: CarContext) : Screen(carContext) {
    private enum class State { READY, RECORDING, SAVED, FAILED }

    private var state = State.READY
    private var detail = ""
    private var recorder: CarRecorder? = null

    init {
        lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onDestroy(owner: LifecycleOwner) {
                    // Session end and car disconnect both end up here. stop()
                    // finalises what was captured so far.
                    recorder?.stop()
                }
            },
        )
    }

    override fun onGetTemplate(): Template {
        if (carContext.carAppApiLevel < MIN_API_LEVEL) {
            return MessageTemplate.Builder("Update Android Auto to use Augustyniak Capture.")
                .setTitle(TITLE)
                .setHeaderAction(Action.APP_ICON)
                .build()
        }
        val builder = when (state) {
            State.READY -> MessageTemplate.Builder("Tap REC and speak your note.")
            State.RECORDING -> MessageTemplate.Builder("Recording…")
            State.SAVED -> MessageTemplate.Builder("Saved")
            State.FAILED -> MessageTemplate.Builder("Could not save. $detail".trim())
        }
        val action = if (state == State.RECORDING) {
            Action.Builder().setTitle("STOP").setOnClickListener { stopRecording() }.build()
        } else {
            Action.Builder().setTitle("REC").setOnClickListener { onRecClicked() }.build()
        }
        return builder.setTitle(TITLE).setHeaderAction(Action.APP_ICON).addAction(action).build()
    }

    private fun onRecClicked() {
        val granted = ContextCompat.checkSelfPermission(
            carContext,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            startRecording()
            return
        }
        carContext.requestPermissions(listOf(Manifest.permission.RECORD_AUDIO)) { allowed, _ ->
            if (allowed.contains(Manifest.permission.RECORD_AUDIO)) {
                startRecording()
            } else {
                show(State.FAILED, "Microphone permission is needed.")
            }
        }
    }

    private fun startRecording() {
        if (recorder != null) return
        val inbox = File(carContext.filesDir, "inbox")
        val next = CarRecorder(carContext, inbox) { result -> onFinished(result) }
        recorder = next
        try {
            next.start()
            state = State.RECORDING
            invalidate()
        } catch (e: Exception) {
            recorder = null
            show(State.FAILED, e.message.orEmpty())
        }
    }

    private fun stopRecording() {
        recorder?.stop()
    }

    private fun onFinished(result: CarCaptureFiles.Result) {
        recorder = null
        when (result) {
            is CarCaptureFiles.Result.Saved -> show(State.SAVED, "")
            is CarCaptureFiles.Result.Failed -> show(State.FAILED, result.reason)
        }
    }

    private fun show(next: State, message: String) {
        state = next
        detail = message
        // After onDestroy the host no longer renders this screen.
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.CREATED)) invalidate()
    }

    private companion object {
        const val TITLE = "Augustyniak Capture"
        const val MIN_API_LEVEL = 5
    }
}
