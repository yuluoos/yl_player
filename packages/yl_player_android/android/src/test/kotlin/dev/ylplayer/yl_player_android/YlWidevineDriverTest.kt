package dev.ylplayer.yl_player_android

import android.media.MediaDrm
import android.media.NotProvisionedException
import android.media.DeniedByServerException
import org.mockito.Mockito.*
import org.mockito.ArgumentCaptor
import kotlin.test.*

class YlWidevineDriverTest {
    private val id = byteArrayOf(1, 2, 3)
    private fun media(): MediaDrm = mock(MediaDrm::class.java).also {
        `when`(it.openSession(MediaDrm.SECURITY_LEVEL_HW_SECURE_ALL)).thenReturn(id.copyOf())
        `when`(it.getSecurityLevel(id)).thenReturn(MediaDrm.SECURITY_LEVEL_HW_SECURE_ALL)
    }
    @Test fun `session requests hardware protection and releases exactly once`() {
        val media = media(); val driver = YlWidevineDriver(36, false, null) { media }
        driver.open {}; driver.close(); driver.close()
        verify(media).openSession(MediaDrm.SECURITY_LEVEL_HW_SECURE_ALL)
        verify(media).closeSession(any(ByteArray::class.java)); verify(media).release()
    }
    @Test fun `lower protection or unknown API capability never falls back`() {
        val media = media()
        `when`(media.getSecurityLevel(id)).thenReturn(MediaDrm.SECURITY_LEVEL_SW_SECURE_CRYPTO)
        val failure = assertFailsWith<YlBoundaryException> { YlWidevineDriver(36, false, null) { media }.open {} }
        assertEquals(YlFailureKind.DRM_PROTECTION_INSUFFICIENT, failure.kind)
        verify(media).closeSession(any(ByteArray::class.java)); verify(media).release()
        var creates = 0
        val unavailable = assertFailsWith<YlBoundaryException> { YlWidevineDriver(24, false, null) { creates++; media }.open {} }
        assertEquals(YlFailureKind.DRM_PROTECTION_INSUFFICIENT, unavailable.kind); assertEquals(0, creates)
        val mode = assertFailsWith<YlBoundaryException> { YlWidevineDriver(24, true, null) { media }.open {} }
        assertEquals(YlFailureKind.DRM_ENCRYPTION_MODE_UNSUPPORTED, mode.kind)
    }
    @Test fun `provisioning is explicit and close failure still releases object`() {
        val media = media()
        `when`(media.openSession(MediaDrm.SECURITY_LEVEL_HW_SECURE_ALL)).thenThrow(NotProvisionedException("private"))
        val failure = assertFailsWith<YlBoundaryException> { YlWidevineDriver(36, false, null) { media }.open {} }
        assertEquals(YlFailureKind.DRM_PROVISIONING_REQUIRED, failure.kind)
        verify(media).release()
        val other = media(); val driver = YlWidevineDriver(36, false, null) { other }
        driver.open {}; doThrow(IllegalStateException("private")).`when`(other).closeSession(id)
        driver.close(); verify(other).release()
    }
    @Test fun `denied response never maps to expired and streaming has no default URL transport`() {
        val media = media(); val driver = YlWidevineDriver(36, false, null) { media }
        val request = mock(MediaDrm.KeyRequest::class.java)
        `when`(request.data).thenReturn(byteArrayOf(8))
        `when`(media.getKeyRequest(eq(id), isNull(), eq("video/mp4"), eq(MediaDrm.KEY_TYPE_STREAMING), eq(hashMapOf<String, String>()))).thenReturn(request)
        driver.open {}; assertContentEquals(byteArrayOf(8), driver.challenge(null, "video/mp4"))
        verify(request, never()).defaultUrl
        `when`(media.provideKeyResponse(id, byteArrayOf(9))).thenThrow(DeniedByServerException("private"))
        assertEquals(YlFailureKind.DRM_LICENSE_DENIED, assertFailsWith<YlBoundaryException> { driver.install(byteArrayOf(9)) }.kind)
        driver.close()
    }
    @Test fun `only current nonempty all-usable statuses are usable and closed callbacks are ignored`() {
        val media = media(); val events = mutableListOf<YlDrmSystemEvent>()
        val driver = YlWidevineDriver(36, false, null) { media }; driver.open { events += it }
        val captor = ArgumentCaptor.forClass(MediaDrm.OnKeyStatusChangeListener::class.java)
        verify(media).setOnKeyStatusChangeListener(captor.capture(), isNull())
        val callback = captor.value
        fun key(code: Int) = mock(MediaDrm.KeyStatus::class.java).also { `when`(it.statusCode).thenReturn(code) }
        callback.onKeyStatusChange(media, byteArrayOf(99), listOf(key(0)), true)
        assertTrue(events.isEmpty())
        callback.onKeyStatusChange(media, id, emptyList(), true)
        assertEquals(YlDrmSystemEvent.PENDING, events.last())
        callback.onKeyStatusChange(media, id, listOf(key(0), key(MediaDrm.KeyStatus.STATUS_PENDING)), true)
        assertEquals(YlDrmSystemEvent.PENDING, events.last())
        callback.onKeyStatusChange(media, id, listOf(key(0)), true)
        assertEquals(YlDrmSystemEvent.USABLE, events.last())
        callback.onKeyStatusChange(media, id, listOf(key(MediaDrm.KeyStatus.STATUS_EXPIRED)), false)
        assertEquals(YlDrmSystemEvent.EXPIRED, events.last())
        driver.close(); val count = events.size
        callback.onKeyStatusChange(media, id, listOf(key(0)), true)
        assertEquals(count, events.size)
    }
    @Test fun `Media3 receives copied secure session handle only while driver is open`() {
        val media = media(); val driver = YlWidevineDriver(36, false, null) { media }
        assertFailsWith<YlBoundaryException> { driver.cryptoConfig() }
        driver.open {}
        val first = driver.cryptoConfig()
        assertFalse(first.forceAllowInsecureDecoderComponents)
        first.sessionId.fill(99)
        assertContentEquals(byteArrayOf(1, 2, 3), driver.cryptoConfig().sessionId)
        driver.close()
        assertFailsWith<YlBoundaryException> { driver.cryptoConfig() }
    }

}
