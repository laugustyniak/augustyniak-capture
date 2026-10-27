package ai.augustyniak.capture.wear

import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.dp
import androidx.wear.protolayout.DimensionBuilders.sp
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ModifiersBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.google.common.util.concurrent.ListenableFuture

/**
 * The fastest path from wrist to recording: one tap on the big button starts
 * it, a second tap stops it. Below it, the count on the watch and its state.
 */
class CaptureTileService : TileService() {
    override fun onTileRequest(requestParams: RequestBuilders.TileRequest): ListenableFuture<TileBuilders.Tile> {
        val recording = RecordingService.isRecording
        val saved = Recordings.savedCount(Recordings.directory(this))
        val tile = TileBuilders.Tile.Builder()
            .setResourcesVersion(RESOURCES_VERSION)
            .setTileTimeline(TimelineBuilders.Timeline.fromLayoutElement(layout(recording, saved)))
            .build()
        return immediate(tile)
    }

    override fun onTileResourcesRequest(
        requestParams: RequestBuilders.ResourcesRequest,
    ): ListenableFuture<ResourceBuilders.Resources> = immediate(
        ResourceBuilders.Resources.Builder()
            .setVersion(RESOURCES_VERSION)
            .addIdToImageMapping(MIC, image(R.drawable.ic_mic))
            .addIdToImageMapping(STOP, image(R.drawable.ic_stop))
            .build(),
    )

    private fun layout(recording: Boolean, saved: Int): LayoutElementBuilders.LayoutElement {
        val toggle = ModifiersBuilders.Clickable.Builder()
            .setId("toggle")
            .setOnClick(
                ActionBuilders.LaunchAction.Builder()
                    .setAndroidActivity(
                        ActionBuilders.AndroidActivity.Builder()
                            .setPackageName(packageName)
                            .setClassName(WearActivity::class.java.name)
                            .addKeyToExtraMapping(
                                WearActivity.EXTRA_COMMAND,
                                ActionBuilders.AndroidStringExtra.Builder().setValue(WearActivity.COMMAND_TOGGLE).build(),
                            )
                            .build(),
                    )
                    .build(),
            )
            .build()
        val button = LayoutElementBuilders.Box.Builder()
            .setWidth(dp(BUTTON))
            .setHeight(dp(BUTTON))
            .setModifiers(
                ModifiersBuilders.Modifiers.Builder()
                    .setBackground(
                        ModifiersBuilders.Background.Builder()
                            .setColor(argb(if (recording) WHITE_12 else ACCENT))
                            .setCorner(ModifiersBuilders.Corner.Builder().setRadius(dp(BUTTON / 2)).build())
                            .build(),
                    )
                    .setClickable(toggle)
                    .setSemantics(
                        ModifiersBuilders.Semantics.Builder()
                            .setContentDescription(if (recording) "Stop and save" else "Record")
                            .build(),
                    )
                    .build(),
            )
            .addContent(
                LayoutElementBuilders.Image.Builder()
                    .setResourceId(if (recording) STOP else MIC)
                    .setWidth(dp(30f))
                    .setHeight(dp(30f))
                    .setColorFilter(
                        LayoutElementBuilders.ColorFilter.Builder().setTint(argb(if (recording) RED else INK)).build(),
                    )
                    .build(),
            )
            .build()
        return LayoutElementBuilders.Column.Builder()
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .addContent(text(if (recording) "Recording" else "Capture", if (recording) RED_TEXT else MUTED))
            .addContent(LayoutElementBuilders.Spacer.Builder().setHeight(dp(8f)).build())
            .addContent(button)
            .addContent(LayoutElementBuilders.Spacer.Builder().setHeight(dp(8f)).build())
            .addContent(text("$saved on watch · local", MUTED))
            .build()
    }

    private fun text(value: String, color: Int) = LayoutElementBuilders.Text.Builder()
        .setText(value)
        .setFontStyle(LayoutElementBuilders.FontStyle.Builder().setSize(sp(13f)).setColor(argb(color)).build())
        .build()

    private fun image(id: Int) = ResourceBuilders.ImageResource.Builder()
        .setAndroidResourceByResId(ResourceBuilders.AndroidImageResourceByResId.Builder().setResourceId(id).build())
        .build()

    private fun <T> immediate(value: T): ListenableFuture<T> =
        CallbackToFutureAdapter.getFuture { completer ->
            completer.set(value)
            "capture-tile"
        }

    private companion object {
        const val RESOURCES_VERSION = "1"
        const val MIC = "mic"
        const val STOP = "stop"
        const val BUTTON = 76f

        // Same tokens as ui/Theme.kt; protolayout takes ARGB ints.
        const val ACCENT = 0xFF59A0F8.toInt()
        const val INK = 0xFF17171C.toInt()
        const val MUTED = 0xFFA0A0AB.toInt()
        const val RED = 0xFFEC5151.toInt()
        const val RED_TEXT = 0xFFEE6363.toInt()
        const val WHITE_12 = 0x1FFFFFFF
    }
}
