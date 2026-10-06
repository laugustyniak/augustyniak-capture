package ai.augustyniak.capture.wear.ui

import ai.augustyniak.capture.wear.R
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.wear.compose.material3.ColorScheme
import androidx.wear.compose.material3.MaterialTheme

/**
 * The augustyniak.ai dark tokens resolved to hex, as `ConsolePalette` does for
 * the phone app (lib/app/ui_kit.dart), plus the watch rules from the Capture
 * Wear OS design: pure black behind everything (OLED), one surface tone, no
 * borders, accent only on the screen's main action.
 */
object Wear {
    val background = Color(0xFF000000)

    /** hsl(240 6% 14%) — every pill, chip and secondary button. */
    val surface = Color(0xFF222226)

    /** `--muted`: progress tracks. */
    val track = Color(0xFF2C2C30)
    val accent = Color(0xFF59A0F8)

    /** `--accent-foreground`. */
    val ink = Color(0xFF17171C)
    val foreground = Color(0xFFEDEBE8)
    val mutedForeground = Color(0xFFA0A0AB)

    /** hsl(0 80% 62%) fill and hsl(0 80% 66%) text. */
    val red = Color(0xFFEC5151)
    val redText = Color(0xFFEE6363)

    /** hsl(152 55% 52%). */
    val green = Color(0xFF41C889)

    /** hsl(38 90% 60%). */
    val amber = Color(0xFFF5B13D)

    val display = FontFamily(Font(R.font.space_grotesk_semibold, FontWeight.SemiBold))

    /** Time only — durations and clock readings. */
    val mono = FontFamily(Font(R.font.jetbrains_mono_medium, FontWeight.Medium))
}

@Composable
fun CaptureTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = ColorScheme(
            primary = Wear.accent,
            onPrimary = Wear.ink,
            background = Wear.background,
            onBackground = Wear.foreground,
            onSurface = Wear.foreground,
            onSurfaceVariant = Wear.mutedForeground,
            surfaceContainer = Wear.surface,
            error = Wear.red,
        ),
        content = content,
    )
}
