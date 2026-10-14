package ai.augustyniak.capture.car

import java.io.File
import java.io.FileInputStream
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

    fun tmpFile(inbox: File, id: String): File = File(inbox, "$id.m4a.tmp")

    fun finalize(tmp: File): Result {
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
