package ai.augustyniak.capture.wear

import android.content.Context
import android.media.MediaMetadataRetriever
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** One file in the watch's `files/recordings/` directory. */
data class WatchRecording(
    val file: File,
    val savedAtMillis: Long,
    val durationMs: Long?,
    val sizeBytes: Long,
    /** `false` for a `.pending` file the recorder never finished renaming. */
    val finished: Boolean,
)

object Recordings {
    fun directory(context: Context) = File(context.filesDir, "recordings")

    /** Finished recordings only, so the count matches what the queue can play. */
    fun savedCount(directory: File): Int =
        directory.listFiles().orEmpty().count { it.isFile && it.extension == "m4a" }

    /**
     * Newest first. [activeFile] is the `.pending` file still being written, which
     * is not an interrupted recording and stays out of the list.
     */
    fun load(directory: File, activeFile: String?, durationOf: (File) -> Long?): List<WatchRecording> =
        directory.listFiles().orEmpty()
            .filter { it.isFile && (it.extension == "m4a" || it.extension == "pending") && it.name != activeFile }
            .sortedByDescending { it.lastModified() }
            .map {
                val finished = it.extension == "m4a"
                WatchRecording(
                    file = it,
                    savedAtMillis = it.lastModified(),
                    durationMs = if (finished) durationOf(it) else null,
                    sizeBytes = it.length(),
                    finished = finished,
                )
            }

    fun durationOf(file: File): Long? = try {
        MediaMetadataRetriever().use { retriever ->
            retriever.setDataSource(file.absolutePath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
        }
    } catch (_: Exception) {
        null
    }
}

/** `00:47`, or `1:02:07` past an hour. */
fun formatDuration(ms: Long): String {
    val total = ms.coerceAtLeast(0) / 1000
    val hours = total / 3600
    val minutes = total % 3600 / 60
    val seconds = total % 60
    return if (hours > 0) {
        String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        String.format(Locale.ROOT, "%02d:%02d", minutes, seconds)
    }
}

/** The queue's second line after the duration: `today`, `yesterday`, then a short date. */
fun formatWhen(savedAtMillis: Long, now: Instant, zone: ZoneId, locale: Locale = Locale.ENGLISH): String {
    val saved = Instant.ofEpochMilli(savedAtMillis).atZone(zone)
    val today = now.atZone(zone).toLocalDate()
    return when (saved.toLocalDate()) {
        today -> "today"
        today.minusDays(1) -> "yesterday"
        else -> saved.format(DateTimeFormatter.ofPattern("d MMM", locale))
    }
}

/** Follows the watch's 12/24-hour setting, so the title agrees with the clock above it. */
fun formatClock(savedAtMillis: Long, zone: ZoneId, is24Hour: Boolean): String =
    Instant.ofEpochMilli(savedAtMillis).atZone(zone)
        .format(DateTimeFormatter.ofPattern(if (is24Hour) "HH:mm" else "h:mm a", Locale.ENGLISH))

fun formatSize(bytes: Long): String =
    if (bytes < 1024 * 1024) "${(bytes + 1023) / 1024} KB"
    else String.format(Locale.ROOT, "%.1f MB", bytes / (1024.0 * 1024.0))

/**
 * Maps `MediaRecorder.getMaxAmplitude()` (0..32767) onto 0..1 over a 50 dB
 * window, so speech fills the waveform rather than only shouting.
 */
fun normalizeLevel(amplitude: Int): Float {
    if (amplitude <= 0) return 0f
    val db = 20 * kotlin.math.log10(amplitude / 32767.0)
    return ((db + 50) / 50).toFloat().coerceIn(0f, 1f)
}
