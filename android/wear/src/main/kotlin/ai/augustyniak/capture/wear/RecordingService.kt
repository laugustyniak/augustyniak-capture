package ai.augustyniak.capture.wear

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import java.io.File
import java.util.UUID

class RecordingService : Service() {
    private var recorder: MediaRecorder? = null
    private var pendingFile: File? = null

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
            publish(false, "Microphone permission required")
            stopSelf()
            return
        }

        val directory = File(filesDir, "recordings")
        if (!directory.isDirectory && !directory.mkdirs()) {
            publish(false, "Could not create recordings directory")
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
            candidate.setOutputFile(file.absolutePath)
            candidate.prepare()
            candidate.start()
            recorder = candidate
            publish(true)
        } catch (error: Exception) {
            candidate?.release()
            file.delete()
            pendingFile = null
            publish(false, "Could not start recording: ${error.message ?: error.javaClass.simpleName}")
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
        val file = pendingFile
        pendingFile = null
        try {
            active.stop()
            val completed = File(file!!.parentFile, "${file.nameWithoutExtension}.m4a")
            if (!file.renameTo(completed)) error("Could not save recording")
            publish(false)
        } catch (error: Exception) {
            publish(false, "Could not save recording: ${error.message ?: error.javaClass.simpleName}")
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

    private fun publish(recording: Boolean, error: String? = null) {
        isRecording = recording
        getSharedPreferences(STATE_PREFERENCES, MODE_PRIVATE).edit()
            .putString(KEY_ERROR, error)
            .apply()
        sendBroadcast(Intent(ACTION_STATE).setPackage(packageName))
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
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Capture is recording")
            .setContentIntent(openApp)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val ACTION_START = "ai.augustyniak.capture.wear.START"
        const val ACTION_STOP = "ai.augustyniak.capture.wear.STOP"
        const val ACTION_STATE = "ai.augustyniak.capture.wear.STATE"
        const val STATE_PREFERENCES = "recording_state"
        const val KEY_ERROR = "error"
        @Volatile var isRecording = false
            private set
        private const val CHANNEL_ID = "capture_recording"
        private const val NOTIFICATION_ID = 1

    }
}
