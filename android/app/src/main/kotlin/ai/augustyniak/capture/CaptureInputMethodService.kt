package ai.augustyniak.capture

import android.content.ClipboardManager
import android.content.Context
import android.inputmethodservice.InputMethodService
import android.graphics.Color
import android.graphics.Typeface
import android.os.Environment
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

class CaptureInputMethodService : InputMethodService(), ClipboardManager.OnPrimaryClipChangedListener {

    private var clipboardManager: ClipboardManager? = null
    private var clipsLayout: LinearLayout? = null
    private var lastText: String? = null

    override fun onCreate() {
        super.onCreate()
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        clipboardManager?.addPrimaryClipChangedListener(this)
    }

    override fun onDestroy() {
        clipboardManager?.removePrimaryClipChangedListener(this)
        super.onDestroy()
    }

    override fun onPrimaryClipChanged() {
        try {
            val clipData = clipboardManager?.primaryClip
            if (clipData != null && clipData.itemCount > 0) {
                val text = clipData.getItemAt(0).text?.toString()
                if (!text.isNullOrBlank() && text != lastText) {
                    lastText = text
                    saveClipToHistory(text)
                    reloadClipsView()
                }
            }
        } catch (_: Exception) {}
    }

    override fun onCreateInputView(): View {
        val rootLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#18181B"))
            setPadding(12, 12, 12, 12)
        }

        // Header bar
        val headerLayout = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(8, 8, 8, 8)
        }

        val titleView = TextView(this).apply {
            text = "✨ AUGUSTYNIAK CAPTURE"
            setTextColor(Color.parseColor("#E4E4E7"))
            typeface = Typeface.DEFAULT_BOLD
            textSize = 13f
        }
        headerLayout.addView(titleView)
        rootLayout.addView(headerLayout)

        // Clipboard horizontal scroll strip
        val scrollView = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
        }
        clipsLayout = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        scrollView.addView(clipsLayout)
        rootLayout.addView(scrollView)

        reloadClipsView()
        return rootLayout
    }

    private fun reloadClipsView() {
        val container = clipsLayout ?: return
        container.removeAllViews()

        val items = loadHistoryClips()
        if (items.isEmpty()) {
            val emptyView = TextView(this).apply {
                text = "Brak skopiowanych elementów w schowku"
                setTextColor(Color.parseColor("#71717A"))
                setPadding(16, 12, 16, 12)
                textSize = 12f
            }
            container.addView(emptyView)
            return
        }

        for (item in items) {
            val chip = Button(this).apply {
                text = if (item.length > 30) item.substring(0, 30) + "..." else item
                isAllCaps = false
                setTextColor(Color.parseColor("#F4F4F5"))
                setBackgroundColor(Color.parseColor("#27272A"))
                textSize = 12f
                setPadding(20, 8, 20, 8)
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                ).apply {
                    setMargins(6, 4, 6, 4)
                }
                setOnClickListener {
                    currentInputConnection?.commitText(item, 1)
                }
            }
            container.addView(chip)
        }
    }

    private fun getStorageFile(): File {
        val docsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
        val appDir = File(docsDir, "AugustyniakCapture")
        if (!appDir.exists()) {
            appDir.mkdirs()
        }
        return File(appDir, "clipboard_history.json")
    }

    private fun loadHistoryClips(): List<String> {
        val list = mutableListOf<String>()
        try {
            val file = getStorageFile()
            if (file.exists()) {
                val raw = file.readText()
                if (raw.isNotBlank()) {
                    val array = JSONArray(raw)
                    for (i in 0 until array.length()) {
                        val obj = array.getJSONObject(i)
                        val text = obj.optString("text")
                        if (!text.isNullOrBlank()) {
                            list.add(text)
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return list
    }

    private fun saveClipToHistory(text: String) {
        try {
            val file = getStorageFile()
            val array = if (file.exists() && file.readText().isNotBlank()) {
                JSONArray(file.readText())
            } else {
                JSONArray()
            }

            val newObj = JSONObject().apply {
                put("id", UUID.randomUUID().toString())
                put("type", "text")
                put("copiedAt", SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).format(Date()))
                put("text", text)
                put("preview", if (text.length > 120) text.substring(0, 120) + "..." else text)
            }

            val newArray = JSONArray()
            newArray.put(newObj)
            for (i in 0 until minOf(array.length(), 99)) {
                newArray.put(array.get(i))
            }

            file.writeText(newArray.toString())
        } catch (_: Exception) {}
    }
}
