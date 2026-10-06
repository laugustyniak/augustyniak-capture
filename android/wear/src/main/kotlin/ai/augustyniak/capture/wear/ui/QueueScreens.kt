package ai.augustyniak.capture.wear.ui

import ai.augustyniak.capture.wear.R
import ai.augustyniak.capture.wear.RecorderState
import ai.augustyniak.capture.wear.Recordings
import ai.augustyniak.capture.wear.WatchRecording
import ai.augustyniak.capture.wear.formatClock
import ai.augustyniak.capture.wear.formatDuration
import ai.augustyniak.capture.wear.formatSize
import ai.augustyniak.capture.wear.formatWhen
import android.media.MediaPlayer
import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.Text
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

@Composable
private fun rememberRecordings(state: RecorderState): List<WatchRecording>? {
    val context = LocalContext.current
    val recordings by produceState<List<WatchRecording>?>(null, state.lastSaved, state.activeFile) {
        value = withContext(Dispatchers.IO) {
            Recordings.load(Recordings.directory(context), state.activeFile, Recordings::durationOf)
        }
    }
    return recordings
}

/**
 * Dot, one-line title, duration and when. The scaling column narrows and dims
 * rows towards the edge; the crown scrolls it.
 */
@Composable
fun QueueScreen(state: RecorderState, onOpen: (String) -> Unit, onRecord: () -> Unit) {
    val recordings = rememberRecordings(state) ?: return
    if (recordings.isEmpty()) {
        EmptyQueue(onRecord)
        return
    }
    val listState = rememberScalingLazyListState()
    val zone = ZoneId.systemDefault()
    val now = Instant.now()
    ScreenScaffold(scrollState = listState) { contentPadding ->
        ScalingLazyColumn(state = listState, contentPadding = contentPadding, modifier = Modifier.fillMaxSize()) {
            item {
                Text("Queue · ${recordings.size}", color = Wear.mutedForeground, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
            items(recordings, key = { it.file.name }) { recording ->
                QueueRow(recording, zone, now, onClick = { onOpen(recording.file.name) })
            }
        }
    }
}

@Composable
private fun QueueRow(recording: WatchRecording, zone: ZoneId, now: Instant, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clip(RoundedCornerShape(50))
            .background(Wear.surface)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Dot(if (recording.finished) Wear.accent else Wear.red, 6.dp)
        Column(Modifier.weight(1f)) {
            Text(
                title(recording, zone),
                color = Wear.foreground,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                listOfNotNull(recording.durationMs?.let(::formatDuration), formatWhen(recording.savedAtMillis, now, zone))
                    .joinToString(" · "),
                color = Wear.mutedForeground,
                fontFamily = Wear.mono,
                fontSize = 11.sp,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun title(recording: WatchRecording, zone: ZoneId): String {
    val is24Hour = DateFormat.is24HourFormat(LocalContext.current)
    return if (recording.finished) "Recording ${formatClock(recording.savedAtMillis, zone, is24Hour)}" else "Unfinished recording"
}

/** A short state and the record button straight away. */
@Composable
private fun EmptyQueue(onRecord: () -> Unit) {
    ScreenScaffold {
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically),
        ) {
            Text("Nothing on watch", color = Wear.mutedForeground, fontSize = 13.sp)
            Text("0", fontFamily = Wear.display, fontWeight = FontWeight.SemiBold, fontSize = 34.sp, color = Wear.foreground)
            Spacer(Modifier.height(2.dp))
            RoundButton(size = 52.dp, color = Wear.accent, onClick = onRecord, label = "Record") {
                Icon(painterResource(R.drawable.ic_mic), contentDescription = null, tint = Wear.ink, modifier = Modifier.size(22.dp))
            }
        }
    }
}

/**
 * Label, title, what is known about the file, and playback. No transcript:
 * nothing is transcribed on the watch.
 */
@Composable
fun DetailScreen(name: String) {
    val context = LocalContext.current
    val recording by produceState<WatchRecording?>(null, name) {
        value = withContext(Dispatchers.IO) {
            Recordings.load(Recordings.directory(context), activeFile = null, Recordings::durationOf)
                .firstOrNull { it.file.name == name }
        }
    }
    val current = recording ?: return
    val zone = ZoneId.systemDefault()
    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { contentPadding ->
        ScalingLazyColumn(state = listState, contentPadding = contentPadding, modifier = Modifier.fillMaxSize()) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    val color = if (current.finished) Wear.accent else Wear.red
                    Dot(color, 5.dp)
                    Text(
                        if (current.finished) "AUDIO · ${formatDuration(current.durationMs ?: 0)}" else "UNFINISHED",
                        color = color,
                        fontSize = 11.sp,
                        letterSpacing = 1.sp,
                    )
                }
            }
            item {
                Text(
                    title(current, zone),
                    fontFamily = Wear.display,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 17.sp,
                    color = Wear.foreground,
                    textAlign = TextAlign.Center,
                )
            }
            item {
                val day = Instant.ofEpochMilli(current.savedAtMillis).atZone(zone)
                    .format(DateTimeFormatter.ofPattern("EEE d MMM", Locale.ENGLISH))
                Text(
                    if (current.finished) "$day · ${formatSize(current.sizeBytes)}" else day,
                    color = Wear.foreground.copy(alpha = .8f),
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                )
            }
            item {
                Text(
                    if (current.finished) "On this watch, not sent yet" else "Stopped before saving. File kept.",
                    color = Wear.mutedForeground,
                    fontSize = 12.sp,
                    textAlign = TextAlign.Center,
                )
            }
            if (current.finished) item { Player(current.file, current.durationMs) }
        }
    }
}

@Composable
private fun Player(file: File, durationMs: Long?) {
    var playing by remember { mutableStateOf(false) }
    var position by remember { mutableLongStateOf(0L) }
    val player = remember(file) { MediaPlayer() }
    DisposableEffect(player) {
        val prepared = runCatching {
            player.setDataSource(file.absolutePath)
            player.prepare()
        }.isSuccess
        if (prepared) player.setOnCompletionListener { playing = false; position = 0 }
        onDispose { player.release() }
    }
    LaunchedEffect(playing) {
        while (playing) {
            position = player.currentPosition.toLong()
            delay(200)
        }
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        RoundButton(
            size = 52.dp,
            color = Wear.accent,
            label = if (playing) "Pause" else "Play",
            onClick = {
                runCatching {
                    if (playing) player.pause() else player.start()
                    playing = !playing
                }
            },
        ) {
            Icon(
                painterResource(if (playing) R.drawable.ic_pause else R.drawable.ic_play),
                contentDescription = null,
                tint = Wear.ink,
                modifier = Modifier.size(20.dp),
            )
        }
        Text(
            listOfNotNull(formatDuration(position), durationMs?.let(::formatDuration)).joinToString(" / "),
            fontFamily = Wear.mono,
            fontSize = 11.sp,
            color = Wear.mutedForeground,
        )
    }
}
