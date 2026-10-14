package dev.ylplayer.yl_player_android

import java.math.BigInteger
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory

/** Exact MPD time until the Media3 microsecond boundary. Arithmetic is reduced
 * before the signed-64-bit storage check; intermediate products never overflow. */
internal data class YlDashTime private constructor(val numerator: Long, val denominator: Long) : Comparable<YlDashTime> {
    operator fun plus(other: YlDashTime) = make(numerator.bi() * other.denominator.bi() + other.numerator.bi() * denominator.bi(), denominator.bi() * other.denominator.bi())
    operator fun minus(other: YlDashTime) = make(numerator.bi() * other.denominator.bi() - other.numerator.bi() * denominator.bi(), denominator.bi() * other.denominator.bi())
    override fun compareTo(other: YlDashTime) = (numerator.bi() * other.denominator.bi()).compareTo(other.numerator.bi() * denominator.bi())
    fun units(scale: Long, ceil: Boolean = false): Long {
        val parts = (numerator.bi() * scale.bi()).divideAndRemainder(denominator.bi())
        val value = parts[0] + if (parts[1].signum() > 0 && ceil) BigInteger.ONE else if (parts[1].signum() < 0 && !ceil) BigInteger.ONE.negate() else BigInteger.ZERO
        return value.checkedLong()
    }
    companion object {
        val ZERO = of(0)
        fun of(numerator: Long, denominator: Long = 1) = make(numerator.bi(), denominator.bi())
        private fun make(n: BigInteger, d: BigInteger): YlDashTime {
            require(d.signum() > 0)
            val gcd = n.gcd(d)
            return YlDashTime((n / gcd).checkedLong(), (d / gcd).checkedLong())
        }
        private fun Long.bi() = BigInteger.valueOf(this)
        // BigInteger.longValueExact is Android API 31. Keep the API 24 floor.
        private fun BigInteger.checkedLong(): Long {
            if (bitLength() > 63) throw ArithmeticException("Time exceeds signed 64-bit storage")
            return toLong()
        }
        fun duration(value: String): YlDashTime {
            require(value.length <= 128)
            val match = Regex("^P(?:(\\d+)D)?(?:T(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)(?:\\.(\\d{1,18}))?S)?)?$").matchEntire(value) ?: error("Invalid duration")
            require((1..4).any { match.groupValues[it].isNotEmpty() })
            var result = ZERO
            for ((index, factor) in listOf(1 to 86400L, 2 to 3600L, 3 to 60L, 4 to 1L)) {
                match.groupValues[index].takeIf(String::isNotEmpty)?.let { result += make(it.toLong().bi() * factor.bi(), BigInteger.ONE) }
            }
            match.groupValues[5].takeIf(String::isNotEmpty)?.let { result += of(it.toLong(), ("1" + "0".repeat(it.length)).toLong()) }
            return result
        }
    }
}

/** Programme windows retain declared gaps and clip overlap at the next start.
 * Missing duration requires every finite AV representation to agree. Text must
 * never establish programme length. This model neither resolves nor fetches URLs. */
internal data class YlDashProgramTiming(val windows: List<Window>, val duration: YlDashTime) {
    data class Window(val start: YlDashTime, val end: YlDashTime, val declaredEnd: YlDashTime)
    private data class Node(val name: String, val attributes: Map<String, String>, val children: MutableList<Node> = mutableListOf()) {
        fun children(name: String) = children.filter { it.name == name }
        fun one(name: String) = children(name).also { require(it.size <= 1) }.firstOrNull()
    }
    companion object {
        fun parse(bytes: ByteArray): YlDashProgramTiming {
            // The production caller runs admission first; retain bounds here too
            // so this pure timing entry point is safe to reuse independently.
            require(bytes.size <= 2 * 1024 * 1024)
            val parser = XmlPullParserFactory.newInstance().apply { isNamespaceAware = true }.newPullParser()
            parser.setInput(bytes.inputStream(), null)
            val stack = mutableListOf<Node>()
            var root: Node? = null
            var elements = 0
            while (parser.eventType != XmlPullParser.END_DOCUMENT) {
                when (parser.eventType) {
                    XmlPullParser.DOCDECL -> error("DTD unsupported")
                    XmlPullParser.START_TAG -> {
                        require(++elements <= 100_000 && stack.size < 64)
                        val attributes = (0 until parser.attributeCount).filter { parser.getAttributeNamespace(it).isNullOrEmpty() }
                            .associate { parser.getAttributeName(it) to parser.getAttributeValue(it) }
                        val node = Node(if (parser.namespace.isNullOrEmpty() || parser.namespace == "urn:mpeg:dash:schema:mpd:2011") parser.name else "", attributes)
                        if (stack.isEmpty()) { require(root == null); root = node } else stack.last().children += node
                        stack += node
                    }
                    XmlPullParser.END_TAG -> stack.removeAt(stack.lastIndex)
                }
                parser.nextToken()
            }
            val mpd = requireNotNull(root)
            require(mpd.name == "MPD" && mpd.attributes["type"].let { it == null || it == "static" })
            val periods = mpd.children("Period")
            require(periods.size in 1..64)
            val total = mpd.attributes["mediaPresentationDuration"]?.let(YlDashTime::duration)
            var cursor = YlDashTime.ZERO
            val declared = periods.mapIndexed { index, period ->
                val start = period.attributes["start"]?.let(YlDashTime::duration) ?: cursor
                val next = periods.getOrNull(index + 1)?.attributes?.get("start")?.let(YlDashTime::duration)
                val span = period.attributes["duration"]?.let(YlDashTime::duration) ?: next?.minus(start)
                    ?: (if (index == periods.lastIndex) total?.minus(start) else null)
                    ?: infer(mpd, period)
                require(start >= YlDashTime.ZERO && span > YlDashTime.ZERO)
                cursor = start + span
                Window(start, cursor, cursor)
            }
            require(total == null || total == cursor)
            val windows = declared.mapIndexed { index, window ->
                val next = declared.getOrNull(index + 1)?.start
                require(next == null || next > window.start)
                window.copy(end = if (next != null) minOf(next, window.end) else window.end)
            }
            require(cursor.units(1_000_000, ceil = true) > 0)
            return YlDashProgramTiming(windows, cursor)
        }
        private fun infer(root: Node, period: Node): YlDashTime {
            val ends = mutableListOf<YlDashTime>()
            for (adaptation in period.children("AdaptationSet")) for (representation in adaptation.children("Representation")) {
                val ancestors = listOf(root, period, adaptation, representation)
                val attributes = ancestors.flatMap { it.attributes.entries }.associate { it.key to it.value }
                val mime = attributes["mimeType"].orEmpty()
                if (attributes["contentType"] !in listOf("video", "audio") && !mime.startsWith("video/") && !mime.startsWith("audio/")) continue
                var kind: String? = null
                var timeline: Node? = null
                var urls: List<Node> = emptyList()
                val address = mutableMapOf<String, String>()
                for (ancestor in ancestors) {
                    val nodes = ancestor.children.filter { it.name in listOf("SegmentTemplate", "SegmentList", "SegmentBase") }
                    require(nodes.size <= 1)
                    val node = nodes.firstOrNull() ?: continue
                    if (kind != node.name) { address.clear(); timeline = null; urls = emptyList() }
                    kind = node.name; address.putAll(node.attributes)
                    node.one("SegmentTimeline")?.let { timeline = it }
                    node.children("SegmentURL").takeIf(List<Node>::isNotEmpty)?.let { urls = it }
                }
                require(kind != null && kind != "SegmentBase")
                val scale = address["timescale"]?.toLong() ?: 1L
                val offset = address["presentationTimeOffset"]?.toLong() ?: 0L
                require(scale > 0 && offset >= 0)
                var end = 0L
                if (timeline != null) {
                    val entries = timeline.children("S")
                    require(entries.isNotEmpty())
                    var count = 0L
                    for (entry in entries) {
                        val start = entry.attributes["t"]?.toLong() ?: end
                        val duration = requireNotNull(entry.attributes["d"]).toLong()
                        val repeat = entry.attributes["r"]?.toLong() ?: 0
                        require(start >= end && duration > 0 && repeat >= 0 && repeat < 100_000)
                        count = Math.addExact(count, repeat + 1)
                        require(count <= 100_000)
                        end = Math.addExact(start, Math.multiplyExact(duration, repeat + 1))
                    }
                    require(kind != "SegmentList" || urls.size.toLong() == count)
                } else {
                    require(kind == "SegmentList" && urls.isNotEmpty())
                    val duration = requireNotNull(address["duration"]).toLong()
                    require(duration > 0)
                    end = Math.multiplyExact(duration, urls.size.toLong())
                }
                ends += YlDashTime.of(Math.subtractExact(end, offset), scale)
            }
            require(ends.isNotEmpty() && ends.all { it == ends.first() } && ends.first() > YlDashTime.ZERO)
            return ends.first()
        }
    }
}
