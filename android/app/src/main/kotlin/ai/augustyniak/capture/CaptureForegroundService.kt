package ai.augustyniak.capture

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the microphone alive while a capture is running and the app is not.
 *
 * **Why this class exists at all.** Since Android 9 microphone access is
 * "while-in-use": the moment the activity stops being visible the system cuts
 * the input, so locking the screen or taking a notification mid-recording ended
 * the capture. Nothing said so — `record` reported no error, the Dart timer
 * carried on counting, and the file simply stopped growing. A dictaphone that
 * only records while you are watching it is not a dictaphone, and a phone is
 * the only device anyone carries.
 *
 * A foreground service with the `microphone` type is the single documented way
 * out. The notification is not decoration: it is the cost of the exemption, and
 * the system will not grant one without it.
 *
 * The service holds no recorder and touches no audio itself — `record` still
 * owns the capture. All this does is keep the process in a state the system
 * will not take the microphone away from, which is why it can start and stop
 * without the recorder ever knowing.
 */
class CaptureForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Declaring the type at runtime as well as in the manifest is what
            // Android 14 checks before it hands over the microphone.
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // NOT_STICKY: if the system kills us the capture is already over, and
        // restarting a service that guards a recording nobody is making would
        // leave a notification claiming the mic is live when it is not.
        return START_NOT_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Recording",
            // LOW: no sound and no heads-up banner. The notification exists so
            // the system grants the microphone and so the user can see a
            // capture is running — interrupting them over their own recording
            // would be noise.
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while a capture is being recorded."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Recording")
            .setContentText("Augustyniak Capture is recording audio.")
            .setSmallIcon(android.R.drawable.presence_audio_online)
            .setContentIntent(open)
            // Not swipeable: dismissing it would suggest the recording had
            // stopped, and it would not have.
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "capture_recording"
        private const val NOTIFICATION_ID = 1001

        fun start(context: Context) {
            val intent = Intent(context, CaptureForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CaptureForegroundService::class.java))
        }
    }
}
