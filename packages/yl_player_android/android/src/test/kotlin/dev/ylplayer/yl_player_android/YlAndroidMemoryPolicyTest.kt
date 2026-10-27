package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals

class YlAndroidMemoryPolicyTest {
    @Test fun `foreground critical pressure trims buffers without destroying the active decoder`() {
        assertEquals(listOf("shrink"), actions(15))
    }

    @Test fun `running moderate and low shrink before pressure becomes critical`() {
        assertEquals(listOf("shrink"), actions(5))
        assertEquals(listOf("shrink"), actions(10))
    }

    @Test fun `intermediate levels use the lower severity threshold`() {
        assertEquals(listOf("shrink"), actions(9))
        assertEquals(listOf("shrink"), actions(14))
        assertEquals(listOf("shrink"), actions(19))
    }

    @Test fun `hidden and background memory notifications still release resources`() {
        for (level in listOf(20, 40, 60, 80)) assertEquals(listOf("release"), actions(level))
    }

    @Test fun `normal memory does not interrupt playback`() {
        assertEquals(emptyList(), actions(0))
    }

    private fun actions(level: Int): List<String> = mutableListOf<String>().also { actions ->
        handleAndroidTrimMemory(level, shrink = { actions += "shrink" }, release = { actions += "release" })
    }
}
