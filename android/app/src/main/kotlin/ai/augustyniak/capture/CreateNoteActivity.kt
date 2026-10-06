package ai.augustyniak.capture

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/**
 * Receives `com.google.android.gms.actions.CREATE_NOTE` (Google Assistant, "take
 * a note ...") and drops the text into the capture inbox without ever opening
 * the app. The Dart side drains `<filesDir>/inbox` once its index has loaded and
 * whenever it comes back to the foreground.
 *
 * The same persist-before-confirm rule as every capture applies: the note is
 * written to `<uuid>.txt.tmp`, synced, renamed to `<uuid>.txt` and its length
 * verified before "Note saved" is shown. The uuid becomes the Recording id, so
 * ingesting the same file twice is idempotent.
 *
 * No Flutter engine, no MainActivity: this runs in a translucent shell and
 * finishes immediately.
 */
class CreateNoteActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val saved = try {
            save(intent)
        } catch (e: Exception) {
            Toast.makeText(this, "Could not save note: ${e.message}", Toast.LENGTH_LONG).show()
            false
        }
        if (saved) {
            Toast.makeText(this, "Note saved", Toast.LENGTH_SHORT).show()
            setResult(RESULT_OK)
        } else {
            setResult(RESULT_CANCELED)
        }
        finish()
    }

    private fun save(intent: Intent?): Boolean {
        val subject = intent?.getStringExtra(Intent.EXTRA_SUBJECT)?.trim().orEmpty()
        val text = intent?.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty()
        val body = listOf(subject, text).filter { it.isNotEmpty() }.joinToString("\n\n")
        if (body.isEmpty()) {
            Toast.makeText(this, "Nothing to save", Toast.LENGTH_SHORT).show()
            return false
        }

        val inbox = File(filesDir, "inbox")
        if (!inbox.isDirectory && !inbox.mkdirs()) {
            throw java.io.IOException("inbox directory unavailable")
        }
        val id = UUID.randomUUID().toString()
        val tmp = File(inbox, "$id.txt.tmp")
        val target = File(inbox, "$id.txt")

        FileOutputStream(tmp).use { out ->
            out.write(body.toByteArray(Charsets.UTF_8))
            out.flush()
            out.fd.sync()
        }
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw java.io.IOException("could not finalise note")
        }
        if (target.length() == 0L) {
            target.delete()
            throw java.io.IOException("note was not persisted")
        }
        return true
    }
}
