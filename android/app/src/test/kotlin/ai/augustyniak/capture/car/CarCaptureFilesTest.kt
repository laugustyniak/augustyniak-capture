package ai.augustyniak.capture.car

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class CarCaptureFilesTest {
    private lateinit var inbox: File

    @Before
    fun setUp() {
        inbox = Files.createTempDirectory("car_inbox").toFile()
    }

    @After
    fun tearDown() {
        inbox.deleteRecursively()
    }

    @Test
    fun newIdMatchesTheDrainerUuidPattern() {
        // Mirrors InboxDrainer._uuid, case-insensitive; the id is also lowercase.
        val pattern = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        repeat(20) { assertTrue(pattern.matches(CarCaptureFiles.newId())) }
        assertNotEquals(CarCaptureFiles.newId(), CarCaptureFiles.newId())
    }

    @Test
    fun tmpFileIsNamedAfterTheIdWithM4aTmp() {
        val id = CarCaptureFiles.newId()
        assertEquals("$id.m4a.tmp", CarCaptureFiles.tmpFile(inbox, id).name)
        assertEquals(inbox, CarCaptureFiles.tmpFile(inbox, id).parentFile)
    }

    @Test
    fun finalizeRenamesANonEmptyTmpToM4a() {
        val id = CarCaptureFiles.newId()
        val tmp = CarCaptureFiles.tmpFile(inbox, id)
        tmp.writeBytes(byteArrayOf(1, 2, 3))

        val result = CarCaptureFiles.finalize(tmp)

        assertTrue(result is CarCaptureFiles.Result.Saved)
        val saved = (result as CarCaptureFiles.Result.Saved).file
        assertEquals("$id.m4a", saved.name)
        assertEquals(3L, saved.length())
        assertFalse(tmp.exists())
    }

    @Test
    fun finalizeFailsOnAZeroLengthTmpAndLeavesNoM4a() {
        val id = CarCaptureFiles.newId()
        val tmp = CarCaptureFiles.tmpFile(inbox, id)
        tmp.writeBytes(ByteArray(0))

        val result = CarCaptureFiles.finalize(tmp)

        assertTrue(result is CarCaptureFiles.Result.Failed)
        assertFalse(File(inbox, "$id.m4a").exists())
    }

    @Test
    fun finalizeFailsOnAMissingTmp() {
        val id = CarCaptureFiles.newId()
        val result = CarCaptureFiles.finalize(CarCaptureFiles.tmpFile(inbox, id))

        assertTrue(result is CarCaptureFiles.Result.Failed)
        assertFalse(File(inbox, "$id.m4a").exists())
    }
}
