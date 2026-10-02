package ai.augustyniak.capture.wear

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.io.File
import java.text.DateFormat
import java.util.Date

class WearActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var recordButton: Button
    private lateinit var recordings: TextView
    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = refresh()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(24, 20, 24, 20)
        }
        column.addView(TextView(this).apply {
            text = getString(R.string.app_title)
            textSize = 18f
            gravity = Gravity.CENTER
        })
        status = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 14f
            setPadding(0, 12, 0, 8)
        }
        column.addView(status)
        recordButton = Button(this).apply { setOnClickListener { toggleRecording() } }
        column.addView(recordButton)
        recordings = TextView(this).apply {
            textSize = 12f
            setPadding(0, 12, 0, 0)
        }
        column.addView(recordings)
        setContentView(ScrollView(this).apply {
            addView(column, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        })
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag") // Android 12 and older have no receiver flag API.
    override fun onStart() {
        super.onStart()
        val filter = IntentFilter(RecordingService.ACTION_STATE)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(stateReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(stateReceiver, filter)
        }
        refresh()
    }

    override fun onStop() {
        unregisterReceiver(stateReceiver)
        super.onStop()
    }

    private fun toggleRecording() {
        if (RecordingService.isRecording) {
            startService(Intent(this, RecordingService::class.java).setAction(RecordingService.ACTION_STOP))
        } else if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            startForegroundService(Intent(this, RecordingService::class.java).setAction(RecordingService.ACTION_START))
        } else {
            val permissions = if (Build.VERSION.SDK_INT >= 33) {
                arrayOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
            } else {
                arrayOf(Manifest.permission.RECORD_AUDIO)
            }
            requestPermissions(permissions, MICROPHONE_REQUEST)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MICROPHONE_REQUEST) return
        val microphoneIndex = permissions.indexOf(Manifest.permission.RECORD_AUDIO)
        if (microphoneIndex >= 0 && grantResults.getOrNull(microphoneIndex) == PackageManager.PERMISSION_GRANTED) {
            startForegroundService(Intent(this, RecordingService::class.java).setAction(RecordingService.ACTION_START))
        } else {
            status.text = getString(R.string.microphone_permission_required)
        }
    }

    private fun refresh() {
        val active = RecordingService.isRecording
        val error = getSharedPreferences(RecordingService.STATE_PREFERENCES, MODE_PRIVATE)
            .getString(RecordingService.KEY_ERROR, null)
        status.text = if (active) "Recording on this watch" else error ?: "Ready to record"
        recordButton.text = if (active) "Stop and save" else "Record"
        val allFiles = File(filesDir, "recordings").listFiles().orEmpty()
        val files = allFiles
            .filter { it.isFile && it.extension == "m4a" }
            .sortedByDescending { it.lastModified() }
        val unfinished = allFiles.count { it.isFile && it.extension == "pending" }
        val savedSummary = if (files.isEmpty()) {
            "No saved recordings"
        } else {
            "Saved on watch: ${files.size}\n" + files.take(5).joinToString("\n") {
                DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(it.lastModified()))
            }
        }
        recordings.text = savedSummary + if (unfinished > 0) "\nUnfinished recordings: $unfinished" else ""
    }

    companion object {
        private const val MICROPHONE_REQUEST = 1
    }
}
