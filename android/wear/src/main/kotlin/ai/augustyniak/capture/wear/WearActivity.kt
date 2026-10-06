package ai.augustyniak.capture.wear

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.mutableIntStateOf
import ai.augustyniak.capture.wear.ui.CaptureApp

class WearActivity : ComponentActivity() {
    /** Bumped when a complication asks for the queue; the nav host watches it. */
    private val queueRequests = mutableIntStateOf(0)

    private val permissionRequest = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        if (grants[Manifest.permission.RECORD_AUDIO] == true) {
            startRecording()
        } else {
            RecordingService.reportError(this, getString(R.string.microphone_permission_required))
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        RecordingService.restore(this)
        setContent { CaptureApp(onToggleRecording = ::toggleRecording, queueRequests = queueRequests) }
        if (savedInstanceState == null) handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        when (intent?.getStringExtra(EXTRA_COMMAND)) {
            COMMAND_TOGGLE -> toggleRecording()
            COMMAND_QUEUE -> queueRequests.intValue++
        }
    }

    private fun toggleRecording() {
        if (RecordingService.isRecording) {
            startService(Intent(this, RecordingService::class.java).setAction(RecordingService.ACTION_STOP))
        } else if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            startRecording()
        } else {
            permissionRequest.launch(
                if (Build.VERSION.SDK_INT >= 33) {
                    arrayOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    arrayOf(Manifest.permission.RECORD_AUDIO)
                },
            )
        }
    }

    private fun startRecording() {
        startForegroundService(Intent(this, RecordingService::class.java).setAction(RecordingService.ACTION_START))
    }

    companion object {
        /**
         * Tiles and complications cannot start a microphone service from the
         * background, so they open this activity with a command instead.
         */
        const val EXTRA_COMMAND = "command"
        const val COMMAND_TOGGLE = "toggle"
        const val COMMAND_QUEUE = "queue"

        fun commandIntent(context: Context, command: String): PendingIntent = PendingIntent.getActivity(
            context,
            command.hashCode(),
            Intent(context, WearActivity::class.java)
                .putExtra(EXTRA_COMMAND, command)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
