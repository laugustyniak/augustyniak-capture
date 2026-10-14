package ai.augustyniak.capture.car

import java.io.File
import java.io.FileInputStream
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
import java.util.UUID

/**
 * File naming and the persist-before-confirm step for the car app, kept free of
 * Android classes so it runs under plain JUnit.
 *
 * A recording is written to `<uuid>.m4a.tmp`; [finalize] syncs it, renames it to
 * `<uuid>.m4a` and verifies it is not empty. Only a [Result.Saved] may be shown
 * to the driver as "Saved". The uuid becomes the Recording id on the Dart side.
 */
object CarCaptureFiles {
    sealed class Result {
        data class Saved(val file: File) : Result()

        data class Failed(val reason: String) : Result()
    }

    /** Lowercase v4 uuid, accepted by the Dart inbox drainer. */
    fun newId(): String = UUID.randomUUID().toString()

    /** Best effort: some filesystems refuse to open or sync a directory. */
    private fun syncDirectory(dir: File?) {
        if (dir == null) return
        try {
            FileChannel.open(dir.toPath(), StandardOpenOption.READ).use { it.force(true) }
        } catch (_: Exception) {
        }
    }

    fun tmpFile(inbox: File, id: String): File = File(inbox, "$id.m4a.tmp")

    /**
     * [samples] is the number of PCM samples that went into [tmp]. Zero means the
     * host closed the microphone at once: the muxer may still have written a
     * valid, empty MP4, and "Saved" would be a lie. There is no audio to lose, so
     * that is the one case where the file is deleted.
     */
    fun finalize(tmp: File, samples: Long): Result {
        if (samples == 0L) {
            tmp.delete()
            return Result.Failed("nothing was recorded")
        }
        if (!tmp.isFile || tmp.length() == 0L) {
            // An empty tmp carries nothing to keep; a missing one is already gone.
            if (tmp.isFile) tmp.delete()
            return Result.Failed("nothing was recorded")
        }
        val target = File(tmp.parentFile, tmp.name.removeSuffix(".tmp"))
        return try {
            FileInputStream(tmp).use { it.fd.sync() }
            if (!tmp.renameTo(target)) {
                return Result.Failed("could not finalise recording")
            }
            syncDirectory(target.parentFile)
            if (target.length() == 0L) {
                target.delete()
                Result.Failed("recording was not persisted")
            } else {
                Result.Saved(target)
            }
        } catch (e: java.io.IOException) {
            Result.Failed(e.message ?: "could not finalise recording")
        }
    }
}
