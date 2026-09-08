package dev.ylplayer.yl_player_android

import android.view.Surface
import kotlin.test.*
import org.mockito.Mockito.mock

class YlCandidateVideoOutputTest {
    @Test fun `private resource releases only after successful public output acknowledgement`() {
        val candidate = FakePrivateOutput()
        val output = YlEngineVideoOutput(candidate)
        val public = mock(Surface::class.java)
        val publicIdentity = YlOutputIdentity(1, true)
        assertFailsWith<IllegalStateException> { output.switchTo(public, publicIdentity) { throw IllegalStateException() } }
        assertEquals(0, candidate.releases)
        assertEquals(candidate.identity, output.renderedIdentity(candidate.surface))
        output.switchTo(public, publicIdentity) { assertEquals(0, candidate.releases) }
        assertEquals(1, candidate.releases)
        assertNull(output.renderedIdentity(candidate.surface))
        assertEquals(publicIdentity, output.renderedIdentity(public))
    }
    @Test fun `rollback retains private resources on unacknowledged detach`() {
        val candidate = FakePrivateOutput()
        val output = YlEngineVideoOutput(candidate)
        assertFailsWith<IllegalStateException> { output.dispose { throw IllegalStateException() } }
        assertEquals(0, candidate.releases)
        output.dispose { }
        output.dispose { }
        assertEquals(1, candidate.releases)
    }
    private class FakePrivateOutput : YlPrivateVideoOutput {
        override val surface = mock(Surface::class.java)
        override val identity = YlOutputIdentity(0, false)
        var releases = 0
        override fun releaseAfterAcknowledgedDetach() { releases++ }
    }
}
