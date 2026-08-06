package ai.augustyniak.capture

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val mediaExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_CHANNEL,
        ).setMethodCallHandler(::handleMediaCall)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CLIPBOARD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method == "getClipboardHistoryDirectory") {
                val directory = File(filesDir, CLIPBOARD_DIRECTORY).apply { mkdirs() }
                result.success(directory.path)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        mediaExecutor.shutdown()
        super.onDestroy()
    }

    private fun handleMediaCall(call: MethodCall, result: MethodChannel.Result) {
        mediaExecutor.execute {
            try {
                val value = when (call.method) {
                    "extractVideoAudio" -> {
                        extractVideoAudio(call.requiredPath("sourcePath"), call.requiredPath("outputPath"))
                        null
                    }
                    "extractVideoPoster" -> {
                        extractVideoPoster(call.requiredPath("sourcePath"), call.requiredPath("outputPath"))
                        null
                    }
                    "splitAudio" -> splitAudio(
                        call.requiredPath("sourcePath"),
                        call.requiredPath("outputDirectory"),
                        call.argument<Number>("segmentMilliseconds")?.toLong()
                            ?: error("Missing segmentMilliseconds."),
                    )
                    else -> {
                        mainHandler.post { result.notImplemented() }
                        return@execute
                    }
                }
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error(
                        "native_media_error",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                }
            }
        }
    }

    private fun extractVideoAudio(sourcePath: String, outputPath: String) {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(sourcePath)
            val inputTrack = extractor.firstTrack("audio/")
            val format = extractor.getTrackFormat(inputTrack)
            extractor.selectTrack(inputTrack)
            File(outputPath).parentFile?.mkdirs()
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val outputTrack = muxer.addTrack(format)
            muxer.start()
            copySamples(extractor, muxer, outputTrack, sampleBufferCapacity(format))
        } finally {
            extractor.release()
            muxer?.stopSafely()
        }
        require(File(outputPath).length() > 0L) { "Video contains no extractable audio." }
    }

    private fun extractVideoPoster(sourcePath: String, outputPath: String) {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(sourcePath)
            val durationUs =
                (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L) * 1_000L
            val requestedUs = if (durationUs > 0L) minOf(1_000_000L, max(0L, durationUs - 1L)) else 0L
            val frame = retriever.getFrameAtTime(
                requestedUs,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            ) ?: error("Video contains no decodable frame.")
            try {
                val height = max(1, (frame.height * (320.0 / frame.width)).roundToInt())
                val scaled = Bitmap.createScaledBitmap(frame, 320, height, true)
                try {
                    File(outputPath).parentFile?.mkdirs()
                    FileOutputStream(outputPath).use { stream ->
                        require(scaled.compress(Bitmap.CompressFormat.JPEG, 85, stream)) {
                            "Could not encode the video poster."
                        }
                    }
                } finally {
                    if (scaled !== frame) scaled.recycle()
                }
            } finally {
                frame.recycle()
            }
        } finally {
            retriever.release()
        }
    }

    private fun splitAudio(
        sourcePath: String,
        outputDirectory: String,
        segmentMilliseconds: Long,
    ): List<String> {
        require(segmentMilliseconds > 0L) { "Segment duration must be positive." }
        val directory = File(outputDirectory).apply { mkdirs() }
        val segmentUs = segmentMilliseconds * 1_000L
        val extractor = MediaExtractor()
        val outputs = mutableListOf<String>()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(sourcePath)
            val inputTrack = extractor.firstTrack("audio/")
            val format = extractor.getTrackFormat(inputTrack)
            extractor.selectTrack(inputTrack)
            val capacity = sampleBufferCapacity(format)
            val buffer = ByteBuffer.allocateDirect(capacity)
            val info = MediaCodec.BufferInfo()
            var outputTrack = -1
            var segmentStartUs = -1L
            var hasSamples = false

            while (true) {
                buffer.clear()
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                val sampleTimeUs = extractor.sampleTime

                if (muxer == null || (hasSamples && sampleTimeUs - segmentStartUs >= segmentUs)) {
                    muxer?.stopSafely()
                    val output = File(directory, "part_${outputs.size.toString().padStart(5, '0')}.m4a")
                    muxer = MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                    outputTrack = muxer.addTrack(format)
                    muxer.start()
                    outputs.add(output.path)
                    segmentStartUs = sampleTimeUs
                    hasSamples = false
                }

                info.set(
                    0,
                    size,
                    sampleTimeUs - segmentStartUs,
                    extractor.sampleFlags,
                )
                muxer.writeSampleData(outputTrack, buffer, info)
                hasSamples = true
                extractor.advance()
            }
        } finally {
            extractor.release()
            muxer?.stopSafely()
        }
        require(outputs.isNotEmpty()) { "Audio contains no extractable samples." }
        return outputs
    }

    private fun copySamples(
        extractor: MediaExtractor,
        muxer: MediaMuxer,
        outputTrack: Int,
        capacity: Int,
    ) {
        val buffer = ByteBuffer.allocateDirect(capacity)
        val info = MediaCodec.BufferInfo()
        var firstSampleUs = -1L
        while (true) {
            buffer.clear()
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) break
            if (firstSampleUs < 0L) firstSampleUs = extractor.sampleTime
            info.set(
                0,
                size,
                extractor.sampleTime - firstSampleUs,
                extractor.sampleFlags,
            )
            muxer.writeSampleData(outputTrack, buffer, info)
            extractor.advance()
        }
        require(firstSampleUs >= 0L) { "Media contains no audio samples." }
    }

    private fun sampleBufferCapacity(format: MediaFormat): Int = max(
        1024 * 1024,
        if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
            format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
        } else {
            0
        },
    )

    private fun MediaExtractor.firstTrack(prefix: String): Int {
        for (index in 0 until trackCount) {
            val mime = getTrackFormat(index).getString(MediaFormat.KEY_MIME)
            if (mime?.startsWith(prefix) == true) return index
        }
        error("Media contains no ${prefix.removeSuffix("/")} track.")
    }

    private fun MediaMuxer.stopSafely() {
        try {
            stop()
        } catch (_: IllegalStateException) {
            // The Dart layer rejects the missing/empty output with context.
        } finally {
            release()
        }
    }

    private fun MethodCall.requiredPath(name: String): String =
        argument<String>(name)?.takeIf { it.isNotBlank() }
            ?: error("Missing $name.")

    companion object {
        private const val MEDIA_CHANNEL = "ai.augustyniak.capture/media_processing"
        private const val CLIPBOARD_CHANNEL = "ai.augustyniak.capture/clipboard"
        private const val CLIPBOARD_DIRECTORY = "AugustyniakCapture"
    }
}
