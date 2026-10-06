package ai.augustyniak.capture.wear

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.wear.tiles.TileService
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.util.UUID

/** What the recorder is doing, shared by the activity, the tile and the complications. */
data class RecorderState(
    val recording: Boolean = false,
    /** `SystemClock.elapsedRealtime()` at start; the UI derives the timer from it. */
    val startedAt: Long = 0,
    /** Name of the `.pending` file being written. */
    val activeFile: String? = null,
    /** Name of the most recent `.m4a` this process saved. */
    val lastSaved: String? = null,
    val lastDurationMs: Long = 0,
    val error: String? = null,
)

class RecordingService : Service() {
    private var recorder: MediaRecorder? = null
    private var pendingFile: File? = null
    private val handler = Handler(Looper.getMainLooper())
    private val sampleLevel = object : Runnable {
        override fun run() {
            val active = recorder ?: return
            mutableLevel.value = try {
                normalizeLevel(active.maxAmplitude)
            } catch (_: IllegalStateException) {
                0f
            }
            handler.postDelayed(this, LEVEL_INTERVAL_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startRecording()
            ACTION_STOP -> stopRecording()
        }
        return START_NOT_STICKY
    }

    private fun startRecording() {
        if (recorder != null) return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            publish(this, RecorderState(error = "Microphone permission required"))
            stopSelf()
            return
        }

        val directory = Recordings.directory(this)
        if (!directory.isDirectory && !directory.mkdirs()) {
            publish(this, RecorderState(error = "Could not create recordings directory"))
            stopSelf()
            return
        }
        val file = File(directory, "${UUID.randomUUID()}.pending")
        pendingFile = file
        var candidate: MediaRecorder? = null
        try {
            createNotificationChannel()
            val notification = notification()
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }

            candidate = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(this) else MediaRecorder()
            candidate.setAudioSource(MediaRecorder.AudioSource.MIC)
            candidate.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            candidate.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            candidate.setAudioEncodingBitRate(64000)
            candidate.setAudioSamplingRate(16000)
            candidate.setOutputFile(file.absolutePath)
            candidate.prepare()
            candidate.start()
            recorder = candidate
            publish(
                this,
                state.value.copy(
                    recording = true,
                    startedAt = SystemClock.elapsedRealtime(),
                    activeFile = file.name,
                    error = null,
                ),
            )
            vibrate()
            handler.post(sampleLevel)
        } catch (error: Exception) {
            candidate?.release()
            file.delete()
            pendingFile = null
            publish(this, RecorderState(error = "Could not start recording: ${error.message ?: error.javaClass.simpleName}"))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun stopRecording() {
        val active = recorder ?: run {
            stopSelf()
            return
        }
        recorder = null
        handler.removeCallbacks(sampleLevel)
        mutableLevel.value = 0f
        val file = pendingFile
        pendingFile = null
        val durationMs = SystemClock.elapsedRealtime() - state.value.startedAt
        try {
            active.stop()
            // Persist before anything else: the file must exist and hold bytes
            // before it is renamed into the queue.
            if (file == null || !file.isFile || file.length() == 0L) error("Recording is empty")
            val completed = File(file.parentFile, "${file.nameWithoutExtension}.m4a")
            if (!file.renameTo(completed)) error("Could not save recording")
            publish(this, RecorderState(lastSaved = completed.name, lastDurationMs = durationMs))
            vibrate()
        } catch (error: Exception) {
            publish(this, RecorderState(error = "Could not save recording: ${error.message ?: error.javaClass.simpleName}"))
        } finally {
            active.release()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    override fun onDestroy() {
        if (recorder != null) stopRecording()
        super.onDestroy()
    }

    private fun vibrate() {
        val vibrator = if (Build.VERSION.SDK_INT >= 31) {
            getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Vibrator::class.java)
        }
        try {
            vibrator?.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK))
        } catch (_: Exception) {
            // Haptics are a courtesy; a recording never fails over them.
        }
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Recording", NotificationManager.IMPORTANCE_LOW),
        )
    }

    private fun notification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, WearActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_mic)
            .setContentTitle("Capture is recording")
            .setContentIntent(openApp)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val ACTION_START = "ai.augustyniak.capture.wear.START"
        const val ACTION_STOP = "ai.augustyniak.capture.wear.STOP"
        private const val STATE_PREFERENCES = "recording_state"
        private const val KEY_ERROR = "error"
        private const val CHANNEL_ID = "capture_recording"
        private const val NOTIFICATION_ID = 1
        private const val LEVEL_INTERVAL_MS = 80L

        private val mutableState = MutableStateFlow(RecorderState())
        val state: StateFlow<RecorderState> = mutableState.asStateFlow()

        private val mutableLevel = MutableStateFlow(0f)

        /** Microphone level, 0..1, sampled while recording. */
        val level: StateFlow<Float> = mutableLevel.asStateFlow()

        val isRecording get() = state.value.recording

        /** Brings back an error from a previous process, which the in-memory state lost. */
        fun restore(context: Context) {
            if (state.value != RecorderState()) return
            val error = context.getSharedPreferences(STATE_PREFERENCES, Context.MODE_PRIVATE).getString(KEY_ERROR, null)
            if (error != null) mutableState.value = RecorderState(error = error)
        }

        fun reportError(context: Context, message: String) = publish(context, state.value.copy(error = message))

        private fun publish(context: Context, next: RecorderState) {
            mutableState.value = next
            context.getSharedPreferences(STATE_PREFERENCES, Context.MODE_PRIVATE).edit()
                .putString(KEY_ERROR, next.error)
                .apply()
            refreshSurfaces(context)
        }

        /** Best effort: a tile or complication that cannot refresh never fails a recording. */
        fun refreshSurfaces(context: Context) {
            try {
                TileService.getUpdater(context).requestUpdate(CaptureTileService::class.java)
                for (source in listOf(RecordComplicationService::class.java, QueueComplicationService::class.java)) {
                    ComplicationDataSourceUpdateRequester
                        .create(context, ComponentName(context, source))
                        .requestUpdateAll()
                }
            } catch (_: Exception) {
            }
        }
    }
}
