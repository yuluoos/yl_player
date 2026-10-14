package dev.ylplayer.yl_player_android

import android.net.Uri
import android.text.TextUtils
import androidx.media3.common.ParserException
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.mockito.Mockito.*
import kotlin.test.*

class YlDashManifestParserTest {
    private val root = "https://media.test/manifest.mpd".toHttpUrl()
    private fun policy() = YlOriginCredentialPolicy(root, mapOf("X-Ordinary" to "ok"), mapOf("X-Key" to "secret"), requireKnownAncestry = true)
    private fun <T> android(block: () -> T): T = mockStatic(Uri::class.java).use { uris ->
        uris.`when`<Uri> { Uri.parse(anyString()) }.thenAnswer { invocation ->
            val value = invocation.getArgument<String>(0)
            mock(Uri::class.java).also { uri -> `when`(uri.toString()).thenReturn(value) }
        }
        mockStatic(TextUtils::class.java).use { text ->
            text.`when`<Boolean> { TextUtils.isEmpty(any()) }.thenAnswer { it.getArgument<CharSequence?>(0).isNullOrEmpty() }
            mockStatic(org.xmlpull.v1.XmlPullParserFactory::class.java).use { factories ->
                val factory = mock(org.xmlpull.v1.XmlPullParserFactory::class.java)
                factories.`when`<org.xmlpull.v1.XmlPullParserFactory> { org.xmlpull.v1.XmlPullParserFactory.newInstance() }.thenReturn(factory)
                `when`(factory.newPullParser()).thenAnswer { org.kxml2.io.KXmlParser().apply { setFeature(org.xmlpull.v1.XmlPullParser.FEATURE_PROCESS_NAMESPACES, true) } }
                mockStatic(android.util.Pair::class.java).use { pairs ->
                    pairs.`when`<android.util.Pair<Any?, Any?>> { android.util.Pair.create<Any?, Any?>(any(), any()) }.thenAnswer { invocation ->
                        mock(android.util.Pair::class.java).also { pair ->
                            android.util.Pair::class.java.getField("first").set(pair, invocation.getArgument<Any?>(0))
                            android.util.Pair::class.java.getField("second").set(pair, invocation.getArgument<Any?>(1))
                        }
                    }
                    block()
                }
            }
        }
    }
    private fun manifest(base: String = "", adaptationBase: String = "", representationBase: String = "", segment: String = template, extra: String = "", type: String = "static") = """
      <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="$type" mediaPresentationDuration="PT4S" minBufferTime="PT1S">
      $base<Period start="PT0S" duration="PT4S"><AdaptationSet mimeType="video/mp4" codecs="avc1.64001e">$adaptationBase$extra
      <Representation id="v" bandwidth="100000" width="64" height="64">$representationBase$segment</Representation>
      </AdaptationSet></Period></MPD>
    """.trimIndent()
    private fun parse(xml: String, policy: YlOriginCredentialPolicy) = YlDashManifestParser(policy).parse(Uri.parse(root.toString()), xml.byteInputStream())
    private fun assertSecret(policy: YlOriginCredentialPolicy, url: String, secret: String?) {
        val request = policy.apply(Request.Builder().url(url).build(), false)
        assertEquals(secret, request.header("X-Key"), url)
        assertEquals("ok", request.header("X-Ordinary"))
    }
    @Test fun `video coverage retains raw rational PTO and does not fill explicit segment holes`() = android {
        val segment = """<SegmentTemplate timescale="3000001" presentationTimeOffset="9000003" initialization="init.mp4" media="v-${'$'}Number${'$'}.m4s"><SegmentTimeline><S t="10000003" d="1000000"/><S t="14000003" d="1000000"/></SegmentTimeline></SegmentTemplate>"""
        val format = parse(manifest(segment = segment), policy()).getPeriod(0).adaptationSets.single().representations.single().format
        val metadata = requireNotNull(format.metadata)
        val coverage = (0 until metadata.length()).map { metadata[it] }.filterIsInstance<YlDashVideoCoverage>().single()
        assertEquals(YlDashTime.of(1000000, 3000001), coverage.ranges.first().start)
        assertFalse(coverage.contains(333333))
        assertTrue(coverage.contains(333334))
        assertFalse(coverage.contains(1_000_000))
        assertTrue(coverage.contains(1_800_000))
        assertFalse(coverage.contains(2_000_000))
    }

    @Test fun `template child requests inherit same origin and unknown paths stay stripped`() = android {
        val policy = policy()
        parse(manifest(base = "<BaseURL>assets/</BaseURL>"), policy)
        for (path in listOf("init-v.mp4", "v-1.m4s", "v-2.m4s")) assertSecret(policy, "https://media.test/assets/$path", "secret")
        assertSecret(policy, "https://media.test/assets/not-listed.m4s", null)
    }
    @Test fun `cross origin BaseURL followed by absolute return origin never restores credentials`() = android {
        val policy = policy()
        parse(manifest(base = "<BaseURL>returned/</BaseURL>"), policy)
        assertSecret(policy, "https://media.test/returned/v-1.m4s", "secret")
        parse(manifest(base = "<BaseURL>https://other.test/assets/</BaseURL>", adaptationBase = "<BaseURL>https://media.test/returned/</BaseURL>"), policy)
        for (path in listOf("init-v.mp4", "v-1.m4s", "v-2.m4s")) assertSecret(policy, "https://media.test/returned/$path", null)
        assertTrue(policy.isStripped("https://media.test/returned/".toHttpUrl()))
    }
    @Test fun `multiple relative base URLs register their own children`() = android {
        val policy = policy()
        parse(manifest(base = "<BaseURL>a/</BaseURL><BaseURL>b/</BaseURL>", adaptationBase = "<BaseURL>nested/</BaseURL>"), policy)
        for (base in listOf("a", "b")) assertSecret(policy, "https://media.test/$base/nested/v-1.m4s", "secret")
    }
    @Test fun `timeline list and single file index register actual request URLs`() = android {
        for (segment in listOf(
            """<SegmentTemplate timescale="1" initialization="init.mp4" media="time-${'$'}Time${'$'}.m4s"><SegmentTimeline><S t="0" d="2" r="1"/></SegmentTimeline></SegmentTemplate>""",
            """<SegmentList duration="2"><Initialization sourceURL="init.mp4"/><SegmentURL media="one.m4s"/><SegmentURL media="two.m4s"/></SegmentList>""",
            """<SegmentBase indexRange="100-199"><Initialization sourceURL="init.mp4" range="0-99"/></SegmentBase>""")) {
            val policy = policy()
            parse(manifest(representationBase = "<BaseURL>https://media.test/video.mp4</BaseURL>", segment = segment), policy)
            assertSecret(policy, "https://media.test/init.mp4", "secret")
            if (segment.contains("SegmentBase")) assertSecret(policy, "https://media.test/video.mp4", "secret")
            else for (path in if (segment.contains("Timeline")) listOf("time-0.m4s", "time-2.m4s") else listOf("one.m4s", "two.m4s")) assertSecret(policy, "https://media.test/$path", "secret")
        }
    }
    @Test fun `dynamic protected and excessive timeline manifests fail before child requests`() = android {
        for (xml in listOf(manifest(type = "dynamic"), manifest(extra = """<ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc"/>"""), manifest(segment = """<SegmentTemplate media="${'$'}Number${'$'}.m4s"><SegmentTimeline><S d="1" r="100001"/></SegmentTimeline></SegmentTemplate>"""))) {
            val error = assertFailsWith<ParserException> { parse(xml, policy()) }
            assertEquals(YlFailureKind.CONTAINER_UNSUPPORTED, assertIs<YlBoundaryException>(error.cause).kind)
        }
    }
    @Test fun `manifest byte and representation admission bounds reject before exposure`() = android {
        for (xml in listOf(
            manifest(base = "<!--" + "x".repeat(2 * 1024 * 1024) + "-->"),
            manifest(extra = "<Representation id=\"overflow\" bandwidth=\"1\"/>".repeat(4097)),
        )) assertFailsWith<ParserException> { parse(xml, policy()) }
    }
    @Test fun `unused sibling BaseURL fanout is bounded before downstream copies`() = android {
        val xml = """<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT4S" minBufferTime="PT1S">
            ${"<BaseURL>assets/</BaseURL>".repeat(129)}<Period duration="PT4S"><AdaptationSet/></Period></MPD>"""
        assertFailsWith<ParserException> { parse(xml, policy()) }
        Unit
    }
    @Test fun `redirected manifest root taints all returned child requests`() = android {
        val policy = policy()
        val redirected = "https://other.test/redirected.mpd".toHttpUrl()
        policy.inherit(root, redirected)
        policy.inherit(redirected, root)
        parse(manifest(base = "<BaseURL>returned/</BaseURL>"), policy)
        assertSecret(policy, "https://media.test/returned/v-1.m4s", null)
    }
    @Test fun `long BaseURL and finite segment expansion obey retained URI budget`() = android {
        val prefix = "a".repeat(3000)
        val xml = manifest(base = "<BaseURL>$prefix/</BaseURL>", segment = """<SegmentTemplate timescale="1000" duration="1" media="${'$'}Number${'$'}.m4s"/>""")
        val error = assertFailsWith<ParserException> { parse(xml, policy()) }
        assertTrue(error.message!!.startsWith("Unsupported DASH manifest."))
        assertFalse(error.message!!.contains(prefix))
        assertEquals("The media container is unsupported.", YlFailureMapper().toMessage(error).message)
        assertEquals(YlFailureKind.CONTAINER_UNSUPPORTED, assertIs<YlBoundaryException>(error.cause).kind)
    }
    @Test fun `individual expanded BaseURL rejects before retained children`() = android {
        val error = assertFailsWith<ParserException> { parse(manifest(base = "<BaseURL>${"a".repeat(8193)}/</BaseURL>"), policy()) }
        assertEquals(YlFailureKind.CONTAINER_UNSUPPORTED, assertIs<YlBoundaryException>(error.cause).kind)
    }
    @Test fun `template expansion and numeric padding are bounded before Media3 formatting`() = android {
        for (segment in listOf(
            """<SegmentTemplate duration="2" media="${'$'}Number%080d${'$'}.m4s"/>""",
            """<SegmentTemplate duration="2" media="${"${'$'}RepresentationID${'$'}".repeat(600)}.m4s"/>""",
        )) assertFailsWith<ParserException> { parse(manifest(segment = segment), policy()) }
    }
    @Test fun `malformed numeric attributes are sanitized as container errors`() = android {
        for (xml in listOf(manifest().replace("<AdaptationSet ", "<AdaptationSet id=\"private-bad-id\" "),
            manifest().replace("bandwidth=\"100000\"", "bandwidth=\"secret-invalid\""))) {
            val error = assertFailsWith<ParserException> { parse(xml, policy()) }
            assertEquals(YlFailureKind.CONTAINER_UNSUPPORTED, assertIs<YlBoundaryException>(error.cause).kind)
            assertFalse(error.toString().contains("private-bad-id"))
            assertFalse(error.toString().contains("secret-invalid"))
        }
    }
    @Test fun `finite segment endpoints infer omitted static programme duration`() = android {
        val xml = manifest().replace(" mediaPresentationDuration=\"PT4S\"", "").replace(" duration=\"PT4S\"", "")
            .replace(template, """<SegmentTemplate media="${'$'}Number${'$'}.m4s" timescale="3" presentationTimeOffset="30"><SegmentTimeline><S t="30" d="1"/></SegmentTimeline></SegmentTemplate>""")
        assertEquals(334L, parse(xml, policy()).durationMs)
    }
    @Test fun `finite preceding Period resolves omitted following start`() = android {
        val xml = manifest().replace(" mediaPresentationDuration=\"PT4S\"", "").replace(" duration=\"PT4S\"", "")
            .replace(template, """<SegmentTemplate media="${'$'}Number${'$'}.m4s"><SegmentTimeline><S d="2" r="1"/></SegmentTimeline></SegmentTemplate>""")
        val period = xml.substringAfter("<Period").substringBefore("</Period>")
        val two = xml.replace("</MPD>", "<Period" + period.replace("start=\"PT0S\"", "duration=\"PT4S\"") + "</Period></MPD>")
        val parsed = parse(two, policy())
        assertEquals(2, parsed.periodCount)
        assertEquals(4000L, parsed.getPeriod(1).startMs)
        assertEquals(8000L, parsed.durationMs)
    }
    @Test fun `programme retains gaps and clips overlap independently from Media3 period durations`() = android {
        val original = manifest()
        val period = "<Period" + original.substringAfter("<Period").substringBefore("</Period>") + "</Period>"
        for ((start, total, end) in listOf(Triple(5, 9, 4), Triple(3, 7, 3))) {
            val xml = original.replace("mediaPresentationDuration=\"PT4S\"", "mediaPresentationDuration=\"PT${total}S\"")
                .replace("</MPD>", period.replace("start=\"PT0S\"", "start=\"PT${start}S\"") + "</MPD>")
            val parsed = parse(xml, policy()) as YlDashProgramManifest
            assertEquals(YlDashTime.of(end.toLong()), parsed.program.windows[0].end)
            assertEquals(YlDashTime.of(start.toLong()), parsed.program.windows[1].start)
            assertEquals(YlDashTime.of(total.toLong()), parsed.program.duration)
        }
    }
    @Test fun `unknown duration rejects disagreement infinite timelines and text-only evidence`() = android {
        val finite = """<SegmentTemplate timescale="3" media="${'$'}Number${'$'}.m4s"><SegmentTimeline><S d="1"/></SegmentTimeline></SegmentTemplate>"""
        val xml = manifest(segment = finite).replace(" mediaPresentationDuration=\"PT4S\"", "").replace(" duration=\"PT4S\"", "")
        val audio = """<AdaptationSet mimeType="audio/mp4"><Representation id="a" bandwidth="1000">${finite.replace("d=\"1\"", "d=\"2\"")}</Representation></AdaptationSet>"""
        for (invalid in listOf(xml.replace("</Period>", "$audio</Period>"), xml.replace("<S d=\"1\"", "<S r=\"-1\" d=\"1\""), xml.replace("video/mp4", "application/ttml+xml"))) {
            assertFailsWith<ParserException> { parse(invalid, policy()) }
        }
    }
    @Test fun `rational programme boundaries avoid fractional accumulation and signed rounding errors`() {
        val third = YlDashTime.of(1, 3)
        assertEquals(YlDashTime.of(1), third + third + third)
        assertEquals(333333L, third.units(1_000_000))
        assertEquals(333334L, third.units(1_000_000, true))
        assertEquals(-333334L, YlDashTime.of(-1, 3).units(1_000_000))
        assertEquals(-333333L, YlDashTime.of(-1, 3).units(1_000_000, true))
        assertEquals(YlDashTime.of(1), YlDashTime.of(Long.MAX_VALUE, Long.MAX_VALUE))
        assertFailsWith<ArithmeticException> { YlDashTime.of(Long.MAX_VALUE) + YlDashTime.of(1) }
        assertEquals(YlDashTime.of(3500000001, 1000000000), YlDashTime.duration("PT3.500000001S"))
    }
    companion object {
        private val template = """<SegmentTemplate timescale="1" duration="2" initialization="init-${'$'}RepresentationID${'$'}.mp4" media="${'$'}RepresentationID${'$'}-${'$'}Number${'$'}.m4s" startNumber="1"/>"""
    }
}
