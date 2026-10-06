package ai.augustyniak.capture.wear

import android.graphics.drawable.Icon
import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.MonochromaticImage
import androidx.wear.watchface.complications.data.MonochromaticImageComplicationData
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.ShortTextComplicationData
import androidx.wear.watchface.complications.data.SmallImage
import androidx.wear.watchface.complications.data.SmallImageComplicationData
import androidx.wear.watchface.complications.data.SmallImageType
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import androidx.wear.watchface.complications.datasource.SuspendingComplicationDataSourceService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Round "Record" complication: starts recording without opening the app first, a second tap stops. */
class RecordComplicationService : SuspendingComplicationDataSourceService() {
    override fun getPreviewData(type: ComplicationType): ComplicationData? = data(type, recording = false)

    override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? =
        data(request.complicationType, RecordingService.isRecording)

    private fun data(type: ComplicationType, recording: Boolean): ComplicationData? {
        val icon = Icon.createWithResource(this, if (recording) R.drawable.ic_stop else R.drawable.ic_mic)
        val description = PlainComplicationText.Builder(if (recording) "Stop and save" else "Record").build()
        val tap = WearActivity.commandIntent(this, WearActivity.COMMAND_TOGGLE)
        return when (type) {
            ComplicationType.MONOCHROMATIC_IMAGE ->
                MonochromaticImageComplicationData.Builder(MonochromaticImage.Builder(icon).build(), description)
                    .setTapAction(tap)
                    .build()
            ComplicationType.SMALL_IMAGE ->
                SmallImageComplicationData.Builder(SmallImage.Builder(icon, SmallImageType.ICON).build(), description)
                    .setTapAction(tap)
                    .build()
            ComplicationType.SHORT_TEXT ->
                ShortTextComplicationData.Builder(
                    PlainComplicationText.Builder(if (recording) "Stop" else "Rec").build(),
                    description,
                )
                    .setMonochromaticImage(MonochromaticImage.Builder(icon).build())
                    .setTapAction(tap)
                    .build()
            else -> null
        }
    }
}

/** Small text complication: how many recordings sit on the watch. Tap opens the queue. */
class QueueComplicationService : SuspendingComplicationDataSourceService() {
    override fun getPreviewData(type: ComplicationType): ComplicationData? = data(type, 3)

    override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
        val saved = withContext(Dispatchers.IO) { Recordings.savedCount(Recordings.directory(this@QueueComplicationService)) }
        return data(request.complicationType, saved)
    }

    private fun data(type: ComplicationType, saved: Int): ComplicationData? {
        if (type != ComplicationType.SHORT_TEXT) return null
        return ShortTextComplicationData.Builder(
            PlainComplicationText.Builder(saved.toString()).build(),
            PlainComplicationText.Builder("$saved recordings on watch").build(),
        )
            .setMonochromaticImage(MonochromaticImage.Builder(Icon.createWithResource(this, R.drawable.ic_mic)).build())
            .setTapAction(WearActivity.commandIntent(this, WearActivity.COMMAND_QUEUE))
            .build()
    }
}
