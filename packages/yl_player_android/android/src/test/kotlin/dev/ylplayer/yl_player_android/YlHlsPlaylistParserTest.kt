package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class YlHlsPlaylistParserTest {
    @Test
    fun `selects the highest master variant within software envelope`() {
        val playlist = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1800000,RESOLUTION=1280x720,FRAME-RATE=30
            720/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,FRAME-RATE=30
            1080/index.m3u8
        """.trimIndent()

        val parsed = YlHlsPlaylistParser.parse(playlist, "https://media.example/master.m3u8")
        val selected = parsed.variants.filter { it.fitsSoftwareEnvelope }.maxBy { it.bandwidth }

        assertEquals("https://media.example/720/index.m3u8", selected.uri)
    }

    @Test
    fun `parses live media sequence init map byte ranges and aes128 key`() {
        val playlist = """
            #EXTM3U
            #EXT-X-MEDIA-SEQUENCE:41
            #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
            #EXT-X-KEY:METHOD=AES-128,URI="keys/1.key",IV=0x0000000000000000000000000000002A
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:2048@720
            seg.mp4
        """.trimIndent()

        val parsed = YlHlsPlaylistParser.parse(playlist, "https://media.example/live/index.m3u8")

        assertTrue(parsed.isLive)
        assertEquals(41, parsed.mediaSequence)
        assertEquals("https://media.example/live/init.mp4", parsed.initialization?.uri)
        assertEquals(YlByteRange(0, 720), parsed.initialization?.range)
        assertEquals(YlByteRange(720, 2048), parsed.segments.single().range)
        assertEquals("https://media.example/live/keys/1.key", parsed.segments.single().key?.uri)
        assertEquals(42, parsed.segments.single().key?.iv?.last()?.toInt())
    }

    @Test
    fun `endlist marks vod and sample aes is rejected`() {
        val vod = YlHlsPlaylistParser.parse(
            "#EXTM3U\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST",
            "https://media.example/vod.m3u8",
        )
        assertFalse(vod.isLive)

        val unsupported = runCatching {
            YlHlsPlaylistParser.parse(
                "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k\"\n#EXTINF:2,\na.ts",
                "https://media.example/vod.m3u8",
            )
        }.exceptionOrNull()
        assertTrue(unsupported is YlBoundaryException)
        assertEquals(YlFailureKind.POLICY_UNSUPPORTED, unsupported.kind)
    }

    @Test
    fun `aes128 without explicit iv derives it from media sequence`() {
        val parsed = YlHlsPlaylistParser.parse(
            "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:257\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:2,\na.ts",
            "https://media.example/vod.m3u8",
        )

        val iv = parsed.segments.single().key?.iv
        assertEquals(1, iv?.get(14)?.toInt())
        assertEquals(1, iv?.get(15)?.toInt())
    }
}
