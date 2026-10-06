package ai.augustyniak.capture.wear.ui

import ai.augustyniak.capture.wear.R
import ai.augustyniak.capture.wear.RecorderState
import ai.augustyniak.capture.wear.RecordingService
import ai.augustyniak.capture.wear.Recordings
import ai.augustyniak.capture.wear.formatDuration
import android.os.SystemClock
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableIntState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.Text
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private const val HOME = "home"
private const val QUEUE = "queue"
private const val DETAIL = "detail"

@Composable
fun CaptureApp(onToggleRecording: () -> Unit, queueRequests: MutableIntState) {
    val state by RecordingService.state.collectAsState()
    CaptureTheme {
        AppScaffold(modifier = Modifier.background(Wear.background)) {
            val nav = rememberSwipeDismissableNavController()
            LaunchedEffect(queueRequests.intValue) {
                if (queueRequests.intValue > 0) nav.navigate(QUEUE) { launchSingleTop = true }
            }
            // A recording started from a tile or complication lands on its own screen.
            LaunchedEffect(state.recording) {
                if (state.recording) nav.popBackStack(HOME, inclusive = false)
            }
            SwipeDismissableNavHost(navController = nav, startDestination = HOME) {
                composable(HOME) {
                    HomeRoute(state, onToggleRecording, onOpenQueue = { nav.navigate(QUEUE) })
                }
                composable(QUEUE) {
                    QueueScreen(
                        state = state,
                        onOpen = { nav.navigate("$DETAIL/$it") },
                        onRecord = onToggleRecording,
                    )
                }
                composable("$DETAIL/{name}") { entry ->
                    DetailScreen(entry.arguments?.getString("name").orEmpty())
                }
            }
        }
    }
}

/** Home switches between the tile-like start screen, recording and the brief saved confirmation. */
@Composable
private fun HomeRoute(state: RecorderState, onToggleRecording: () -> Unit, onOpenQueue: () -> Unit) {
    val alreadySaved = remember { state.lastSaved }
    var confirming by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(state.lastSaved) {
        val saved = state.lastSaved
        if (saved != null && saved != alreadySaved) {
            confirming = saved
            delay(2_000)
            confirming = null
        }
    }
    ScreenScaffold {
        when {
            state.recording -> RecordingScreen(state, onStop = onToggleRecording)
            confirming != null -> SavedScreen(state.lastDurationMs)
            else -> StartScreen(state, onToggleRecording, onOpenQueue)
        }
    }
}

@Composable
private fun StartScreen(state: RecorderState, onRecord: () -> Unit, onOpenQueue: () -> Unit) {
    val context = LocalContext.current
    val saved by produceState(0, state.lastSaved) {
        value = withContext(Dispatchers.IO) { Recordings.savedCount(Recordings.directory(context)) }
    }
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Spacer(Modifier.height(12.dp))
        Text("Capture", color = Wear.mutedForeground, fontSize = 13.sp)
        Spacer(Modifier.height(8.dp))
        RoundButton(size = 84.dp, color = Wear.accent, onClick = onRecord, label = "Record") {
            Icon(painterResource(R.drawable.ic_mic), contentDescription = null, tint = Wear.ink, modifier = Modifier.size(32.dp))
        }
        Row(
            modifier = Modifier
                .heightIn(min = 48.dp)
                .clip(RoundedCornerShape(24.dp))
                .clickable(onClickLabel = "Open queue", onClick = onOpenQueue)
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("$saved on watch", color = Wear.mutedForeground, fontSize = 13.sp)
            // Nothing leaves the watch yet: the honest state is "local", not "sync".
            Dot(Wear.amber, 6.dp)
            Text("local", color = Wear.mutedForeground, fontSize = 13.sp)
        }
        state.error?.let {
            Text(
                it,
                color = Wear.redText,
                fontSize = 12.sp,
                textAlign = TextAlign.Center,
                maxLines = 2,
            )
        }
    }
}

@Composable
private fun RecordingScreen(state: RecorderState, onStop: () -> Unit) {
    val now by produceState(SystemClock.elapsedRealtime()) {
        while (true) {
            value = SystemClock.elapsedRealtime()
            delay(100)
        }
    }
    val elapsed = (now - state.startedAt).coerceAtLeast(0)
    val bars = remember { mutableStateListOf<Float>().apply { repeat(WAVE_BARS) { add(0f) } } }
    LaunchedEffect(Unit) {
        while (true) {
            bars.removeAt(0)
            bars.add(RecordingService.level.value)
            delay(100)
        }
    }
    Box(Modifier.fillMaxSize()) {
        // The edge ring fills once a minute.
        Canvas(Modifier.fillMaxSize().padding(2.dp)) {
            val stroke = 3.dp.toPx()
            drawArc(
                color = Wear.red,
                startAngle = -90f,
                sweepAngle = 360f * (elapsed % 60_000) / 60_000f,
                useCenter = false,
                topLeft = androidx.compose.ui.geometry.Offset(stroke / 2, stroke / 2),
                size = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke),
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
        }
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(7.dp, Alignment.CenterVertically),
        ) {
            Spacer(Modifier.height(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Dot(Wear.red, 6.dp)
                Text("Recording", color = Wear.redText, fontSize = 13.sp)
            }
            Text(formatDuration(elapsed), fontFamily = Wear.mono, fontSize = 30.sp, color = Wear.foreground)
            Row(
                modifier = Modifier.height(24.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                bars.forEach { level ->
                    Box(
                        Modifier
                            .width(3.dp)
                            .height((3 + level * 21).dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(Wear.accent),
                    )
                }
            }
            RoundButton(size = 52.dp, color = Color.White.copy(alpha = .12f), onClick = onStop, label = "Stop and save") {
                Box(Modifier.size(16.dp).clip(RoundedCornerShape(3.dp)).background(Wear.red))
            }
        }
    }
}

@Composable
private fun SavedScreen(durationMs: Long) {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically),
    ) {
        Box(
            Modifier.size(46.dp).clip(CircleShape).background(Wear.green.copy(alpha = .18f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(painterResource(R.drawable.ic_check), contentDescription = null, tint = Wear.green, modifier = Modifier.size(22.dp))
        }
        Text("Saved", fontFamily = Wear.display, fontWeight = FontWeight.SemiBold, fontSize = 18.sp, color = Wear.foreground)
        Row {
            Text(formatDuration(durationMs), fontFamily = Wear.mono, fontSize = 12.sp, color = Wear.mutedForeground)
            Text(" · on this watch", fontSize = 12.sp, color = Wear.mutedForeground)
        }
    }
}

@Composable
internal fun RoundButton(
    size: androidx.compose.ui.unit.Dp,
    color: Color,
    onClick: () -> Unit,
    label: String,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(color)
            .clickable(onClickLabel = label, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { content() }
}

@Composable
internal fun Dot(color: Color, size: androidx.compose.ui.unit.Dp) {
    Box(Modifier.size(size).clip(CircleShape).background(color))
}

private const val WAVE_BARS = 20
