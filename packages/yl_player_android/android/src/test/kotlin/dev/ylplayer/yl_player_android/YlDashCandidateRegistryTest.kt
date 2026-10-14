package dev.ylplayer.yl_player_android

import okhttp3.HttpUrl.Companion.toHttpUrl
import kotlin.test.*

class YlDashCandidateRegistryTest {
    private val a = "https://a.test/video".toHttpUrl()
    private val b = "https://b.test/video".toHttpUrl()
    private val c = "https://c.test/video".toHttpUrl()
    @Test fun `lookup ignores Media3 choice and retains declaration order`() {
        val registry = YlDashCandidateRegistry()
        registry.publish(listOf(listOf(a, b)))
        assertEquals(listOf(a, b), registry.candidatesFor(b))
        assertEquals(listOf(c), registry.candidatesFor(c))
        registry.publish(listOf(listOf(c, b)))
        assertEquals(listOf(c, b), registry.candidatesFor(b))
        assertEquals(listOf(a), registry.candidatesFor(a))
    }
    @Test fun `bounded conflicting graph publication cannot replace accepted alternatives`() {
        val registry = YlDashCandidateRegistry(maxUrls = 2)
        registry.publish(listOf(listOf(a, b), listOf(a, b)))
        assertFailsWith<IllegalArgumentException> { registry.publish(listOf(listOf(a, b), listOf(b, a))) }
        assertEquals(listOf(a, b), registry.candidatesFor(b))
        assertFailsWith<IllegalArgumentException> { registry.publish(listOf(listOf(a, b, c))) }
        assertEquals(listOf(a, b), registry.candidatesFor(b))
        assertFailsWith<IllegalArgumentException> { YlDashCandidateRegistry(maxCharacters = 1).publish(listOf(listOf(a, b))) }
    }
}
