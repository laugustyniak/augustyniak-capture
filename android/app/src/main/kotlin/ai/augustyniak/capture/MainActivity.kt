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
import java.io.BufferedOutputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SESSION_CHANNEL,
        ).setMethodCallHandler(::handleSessionCall)
    }

    /**
     * Starting and stopping the microphone foreground service.
     *
     * Handled on the main thread rather than on [mediaExecutor]: these calls
     * are two intents and must land *before* the recorder opens the input, so
     * queueing them behind a running media job would be exactly the wrong
     * order. See [CaptureForegroundService] for why the service is needed.
     */
    private fun handleSessionCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "begin" -> {
                    CaptureForegroundService.start(this)
                    result.success(true)
                }
                "end" -> {
                    CaptureForegroundService.stop(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            // Reported rather than swallowed here; the Dart side decides that a
            // capture is worth more than its background guarantee and carries
            // on. Losing the error too would leave no trace at all.
            result.error(
                "capture_session_error",
                error.message ?: error.javaClass.simpleName,
                null,
            )
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
                    "decodeAudioToPcm" -> {
                        decodeAudioToPcm(
                            call.requiredPath("sourcePath"),
                            call.requiredPath("outputPath"),
                            call.argument<Number>("sampleRate")?.toInt()
                                ?: error("Missing sampleRate."),
                        )
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

    /// Decodes any audio track this device can read into the one format a
    /// speech model takes: headerless 16 kHz mono 32-bit float, little-endian.
    ///
    /// **The resample is nearest-sample, and that is a deliberate floor rather
    /// than an oversight.** Whisper's own front end is a mel spectrogram over a
    /// 16 kHz signal; the artefacts a linear or windowed resampler would remove
    /// sit well above what that representation keeps. Android ships no
    /// resampler reachable from here, and pulling one in for a difference the
    /// model cannot see would be a dependency bought for nothing.
    private fun decodeAudioToPcm(sourcePath: String, outputPath: String, sampleRate: Int) {
        require(sampleRate > 0) { "Sample rate must be positive." }
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        val output = File(outputPath)
        output.parentFile?.mkdirs()

        try {
            extractor.setDataSource(sourcePath)
            val track = extractor.firstTrack("audio/")
            val format = extractor.getTrackFormat(track)
            extractor.selectTrack(track)

            val mime = format.getString(MediaFormat.KEY_MIME)
                ?: error("Audio track has no MIME type.")
            val sourceRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val sourceChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            // Carried across buffers: a decoder hands back arbitrary chunk
            // sizes, and a per-buffer counter would restart the resample phase
            // at every boundary and drift the whole track.
            var sourceFrame = 0L
            var written = 0L

            DataOutputStream(BufferedOutputStream(FileOutputStream(output))).use { sink ->
                while (!outputDone) {
                    if (!inputDone) {
                        val index = codec.dequeueInputBuffer(TIMEOUT_US)
                        if (index >= 0) {
                            val buffer = codec.getInputBuffer(index)!!
                            val size = extractor.readSampleData(buffer, 0)
                            if (size < 0) {
                                codec.queueInputBuffer(
                                    index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }

                    val index = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                    if (index >= 0) {
                        val buffer = codec.getOutputBuffer(index)
                        if (buffer != null && info.size > 0) {
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            val shorts = buffer.order(ByteOrder.nativeOrder()).asShortBuffer()
                            val frames = shorts.remaining() / sourceChannels
                            for (frame in 0 until frames) {
                                // Downmix first, then decide whether this frame
                                // survives the rate change: averaging after the
                                // decision would drop one channel's content.
                                var sum = 0f
                                for (channel in 0 until sourceChannels) {
                                    sum += shorts.get(frame * sourceChannels + channel) / 32768f
                                }
                                val sample = sum / sourceChannels

                                val wanted = (sourceFrame + 1) * sampleRate / sourceRate
                                if (wanted > written) {
                                    // Little-endian explicitly: DataOutputStream
                                    // writes big-endian, and the Dart side reads
                                    // these back as a native-order Float32List.
                                    sink.writeInt(
                                        Integer.reverseBytes(
                                            java.lang.Float.floatToIntBits(sample),
                                        ),
                                    )
                                    written++
                                }
                                sourceFrame++
                            }
                        }
                        codec.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputDone = true
                        }
                    }
                }
            }

            // An empty file is the failure this whole path exists to avoid: a
            // model handed silence does not fail, it returns confident
            // nonsense. The Dart side checks the file too; failing here names
            // the cause instead of the symptom.
            require(written > 0L) { "Audio decoded to no samples." }
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
                // A decoder that will not stop cleanly has still produced
                // whatever it produced; releasing it is what matters.
            }
            codec?.release()
            extractor.release()
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
        private const val SESSION_CHANNEL = "ai.augustyniak.capture/capture_session"

        // Long enough that the loop is not a spin, short enough that a codec
        // which stalls still lets the surrounding loop notice end-of-stream.
        private const val TIMEOUT_US = 10_000L
    }
}
