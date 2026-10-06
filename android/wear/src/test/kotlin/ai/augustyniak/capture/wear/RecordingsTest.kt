package ai.augustyniak.capture.wear

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.Instant
import java.time.ZoneId

class RecordingsTest {
    @get:Rule val folder = TemporaryFolder()

    private val zone = ZoneId.of("Europe/Warsaw")
    private val now = Instant.parse("2026-10-05T10:42:00Z")

    @Test fun durationIsMinutesAndSecondsUnderAnHour() {
        assertEquals("00:47", formatDuration(47_900))
        assertEquals("02:07", formatDuration(127_000))
    }

    @Test fun durationGainsHoursPastAnHour() {
        assertEquals("1:02:07", formatDuration(3_727_000))
    }

    @Test fun negativeDurationReadsAsZero() {
        assertEquals("00:00", formatDuration(-5))
    }

    @Test fun whenIsTodayYesterdayThenADate() {
        assertEquals("today", formatWhen(Instant.parse("2026-10-05T07:15:00Z").toEpochMilli(), now, zone))
        assertEquals("yesterday", formatWhen(Instant.parse("2026-10-04T20:00:00Z").toEpochMilli(), now, zone))
        assertEquals("29 Sep", formatWhen(Instant.parse("2026-09-29T08:00:00Z").toEpochMilli(), now, zone))
    }

    @Test fun whenUsesTheWatchZoneNotUtc() {
        // 23:30 UTC on the 4th is already the 5th in Warsaw.
        assertEquals("today", formatWhen(Instant.parse("2026-10-04T23:30:00Z").toEpochMilli(), now, zone))
    }

    @Test fun clockFollowsTheWatchHourSetting() {
        val savedAt = Instant.parse("2026-10-05T18:33:00Z").toEpochMilli()
        assertEquals("20:33", formatClock(savedAt, zone, is24Hour = true))
        assertEquals("8:33 PM", formatClock(savedAt, zone, is24Hour = false))
    }

    @Test fun levelMapsSilenceToZeroAndFullScaleToOne() {
        assertEquals(0f, normalizeLevel(0), 0f)
        assertEquals(1f, normalizeLevel(32767), 0.0001f)
        assertEquals(0.5f, normalizeLevel(1843), 0.01f) // -25 dB, ordinary speech, fills half the bar
        assertEquals(0f, normalizeLevel(100), 0f) // below the 50 dB window
    }

    @Test fun loadListsNewestFirstAndKeepsInterruptedRecordings() {
        val dir = folder.newFolder("recordings")
        file(dir, "old.m4a", 1_000)
        file(dir, "interrupted.pending", 2_000)
        file(dir, "new.m4a", 3_000)
        file(dir, "notes.txt", 4_000)

        val loaded = Recordings.load(dir, activeFile = null) { 5_000L }

        assertEquals(listOf("new.m4a", "interrupted.pending", "old.m4a"), loaded.map { it.file.name })
        assertEquals(listOf(true, false, true), loaded.map { it.finished })
        assertEquals(listOf(5_000L, null, 5_000L), loaded.map { it.durationMs })
    }

    @Test fun loadSkipsTheFileStillBeingRecorded() {
        val dir = folder.newFolder("recordings")
        file(dir, "saved.m4a", 1_000)
        file(dir, "live.pending", 2_000)

        assertEquals(listOf("saved.m4a"), Recordings.load(dir, activeFile = "live.pending") { null }.map { it.file.name })
    }

    @Test fun savedCountIgnoresUnfinishedFiles() {
        val dir = folder.newFolder("recordings")
        file(dir, "a.m4a", 1)
        file(dir, "b.pending", 2)
        assertEquals(1, Recordings.savedCount(dir))
    }

    @Test fun missingDirectoryIsAnEmptyQueue() {
        val dir = File(folder.root, "absent")
        assertEquals(0, Recordings.savedCount(dir))
        assertEquals(emptyList<WatchRecording>(), Recordings.load(dir, null) { null })
    }

    private fun file(dir: File, name: String, modified: Long) =
        File(dir, name).apply {
            writeBytes(byteArrayOf(1, 2, 3))
            setLastModified(modified)
        }
}
