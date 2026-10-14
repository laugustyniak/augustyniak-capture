package ai.augustyniak.capture.car

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.car.app.CarContext
import androidx.car.app.media.CarAudioRecord
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Records the car microphone to `<uuid>.m4a.tmp` as AAC-LC, 16 kHz, mono,
 * 64 kbps (the app's mic-capture defaults), then hands the file to
 * [CarCaptureFiles.finalize]. [onFinished] runs once, on the main thread.
 *
 * [stop] is idempotent and safe from any thread; it is what STOP, a focus loss,
 * the screen's onDestroy and a car disconnect all call. A host that closes the
 * microphone ends the read loop by itself, with the same result.
 */
class CarRecorder(
    private val carContext: CarContext,
    private val inbox: File,
    private val onFinished: (CarCaptureFiles.Result) -> Unit,
) {
    private val stopRequested = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())
    private val audioManager = carContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
        ) {
            stop()
        }
    }
    private var focusRequest: AudioFocusRequest? = null
    private var record: CarAudioRecord? = null
    private var tmp: File? = null

    /** Takes audio focus and starts the worker; throws if recording cannot begin. */
    fun start() {
        if (!inbox.isDirectory && !inbox.mkdirs()) {
            throw java.io.IOException("inbox directory unavailable")
        }
        if (!requestFocus()) {
            throw IllegalStateException("Audio is in use by another app.")
        }
        try {
            val next = CarAudioRecord.create(carContext)
            next.startRecording()
            record = next
            val file = CarCaptureFiles.tmpFile(inbox, CarCaptureFiles.newId())
            tmp = file
            Thread({ run(next, file) }, "car-recorder").start()
        } catch (e: Exception) {
            abandonFocus()
            throw e
        }
    }

    fun stop() {
        if (!stopRequested.compareAndSet(false, true)) return
        try {
            // Unblocks a read() that is waiting on the host's pipe.
            record?.stopRecording()
        } catch (_: Exception) {
        }
    }

    private fun run(source: CarAudioRecord, file: File) {
        var codec: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        var failure: String? = null
        try {
            val format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                SAMPLE_RATE,
                1,
            ).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, BUFFER_BYTES)
            }
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            var track = -1
            val info = MediaCodec.BufferInfo()
            val pcm = ByteArray(BUFFER_BYTES)
            var samples = 0L
            var inputDone = false
            var outputDone = false

            while (!outputDone) {
                if (!inputDone) {
                    val index = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (index >= 0) {
                        val read = if (stopRequested.get()) -1 else readPcm(source, pcm)
                        val ptsUs = samples * 1_000_000L / SAMPLE_RATE
                        if (read <= 0) {
                            codec.queueInputBuffer(
                                index, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            val buffer = codec.getInputBuffer(index)!!
                            buffer.clear()
                            buffer.put(pcm, 0, read)
                            codec.queueInputBuffer(index, 0, read, ptsUs, 0)
                            samples += read / 2
                        }
                    }
                }
                val out = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        muxerStarted = true
                    }
                    out >= 0 -> {
                        val data = codec.getOutputBuffer(out)!!
                        val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        if (!isConfig && info.size > 0 && muxerStarted) {
                            data.position(info.offset)
                            data.limit(info.offset + info.size)
                            muxer.writeSampleData(track, data, info)
                        }
                        codec.releaseOutputBuffer(out, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputDone = true
                        }
                    }
                }
            }
        } catch (e: Exception) {
            failure = e.message ?: e.javaClass.simpleName
        } finally {
            try {
                if (muxerStarted) muxer?.stop()
            } catch (e: Exception) {
                failure = failure ?: (e.message ?: "could not close recording")
            }
            try { muxer?.release() } catch (_: Exception) {}
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            try { source.stopRecording() } catch (_: Exception) {}
            abandonFocus()
        }
        // On an error the half-written tmp stays where it is: it may be all the
        // user has, and the Dart drainer logs it for manual recovery.
        val result = if (failure != null) {
            CarCaptureFiles.Result.Failed(failure)
        } else {
            CarCaptureFiles.finalize(file)
        }
        main.post { onFinished(result) }
    }

    /** -1 once the host closed the microphone or the recording was stopped. */
    private fun readPcm(source: CarAudioRecord, buffer: ByteArray): Int =
        try {
            source.read(buffer, 0, buffer.size)
        } catch (_: Exception) {
            -1
        }

    private fun requestFocus(): Boolean {
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            focusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE,
            )
        }
        return granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusListener)
        }
    }

    private companion object {
        // CarAudioRecord delivers 16 kHz, 16-bit mono PCM.
        const val SAMPLE_RATE = CarAudioRecord.AUDIO_CONTENT_SAMPLING_RATE
        const val BIT_RATE = 64_000
        const val BUFFER_BYTES = 4096
        const val TIMEOUT_US = 10_000L
    }
}
