package dev.ylplayer.yl_player_android

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.ParserException
import androidx.media3.exoplayer.dash.manifest.BaseUrl
import androidx.media3.exoplayer.dash.manifest.DashManifest
import androidx.media3.exoplayer.dash.manifest.DashManifestParser
import androidx.media3.exoplayer.dash.manifest.Representation
import androidx.media3.exoplayer.dash.manifest.SegmentBase
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.ByteArrayOutputStream
import java.io.InputStream

/** Static, clear DASH only. Media3 owns syntax, inheritance and segment URL expansion.
 * Every request URL inherits its exact BaseURL path before the manifest is exposed.
 * Limits bound parsing/graph allocation; they do not claim bounded media buffering. */
internal class YlDashManifestParser(private val credentials: YlOriginCredentialPolicy?) : DashManifestParser() {
    private var timelineElements = 0
    private var registeredEdges = 0
    private var uriCharacters = 0L
    // Identity, not list equality: shared ancestor lists accumulate sibling fanout.
    private val baseUrlResults = java.util.IdentityHashMap<List<BaseUrl>, Int>()

    override fun parse(uri: Uri, inputStream: InputStream): DashManifest {
        timelineElements = 0
        registeredEdges = 0
        baseUrlResults.clear()
        uriCharacters = 0
        reserveUris(uri.toString())
        val bytes = ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        while (true) {
            val read = inputStream.read(chunk)
            if (read < 0) break
            if (bytes.size() + read > MAX_MANIFEST_BYTES) unsupported()
            bytes.write(chunk, 0, read)
        }
        val document = bytes.toByteArray()
        preflight(document)
        val manifest = super.parse(uri, document.inputStream())
        if (manifest.dynamic || manifest.durationMs == C.TIME_UNSET) unsupported()
        var representations = 0
        for (periodIndex in 0 until manifest.periodCount) {
            val durationUs = manifest.getPeriodDurationUs(periodIndex)
            if (durationUs <= 0 || durationUs == C.TIME_UNSET) unsupported()
            for (adaptation in manifest.getPeriod(periodIndex).adaptationSets) {
                for (representation in adaptation.representations) {
                    if (++representations > MAX_REPRESENTATIONS || representation.format.drmInitData != null) unsupported()
                    val index = representation.index
                    val count = index?.getSegmentCount(durationUs)
                    if (index != null && (count == null || count < 0 || count > MAX_GRAPH_EDGES)) unsupported()
                    if (index == null && representation !is Representation.SingleSegmentRepresentation) unsupported()
                    if (representation.baseUrls.size > MAX_BASE_URLS) unsupported()
                    for (base in representation.baseUrls) {
                        representation.initializationUri?.let { inherit(base.url, it.resolveUriString(base.url)) }
                        representation.indexUri?.let { inherit(base.url, it.resolveUriString(base.url)) }
                        if (representation is Representation.SingleSegmentRepresentation) {
                            // A sidx supplies byte ranges within this same resource, not arbitrary child URLs.
                            inherit(base.url, base.url)
                        }
                        if (index != null) {
                            val first = index.firstSegmentNum
                            for (offset in 0L until checkNotNull(count)) {
                                if (first > Long.MAX_VALUE - offset) unsupported()
                                inherit(base.url, index.getSegmentUrl(first + offset).resolveUriString(base.url))
                            }
                        }
                    }
                }
            }
        }
        return manifest
    }

    override fun parseBaseUrl(xpp: XmlPullParser, parentBaseUrls: MutableList<BaseUrl>, dvbProfileDeclared: Boolean): MutableList<BaseUrl> {
        if (parentBaseUrls.size > MAX_BASE_URLS) unsupported()
        parentBaseUrls.forEach { checkUriLength(it.url) }
        // Raw BaseURL text was length-checked in preflight; each temporary resolution
        // is bounded by two capped inputs, even before super returns its alternatives.
        val resolved = super.parseBaseUrl(xpp, parentBaseUrls, dvbProfileDeclared)
        val total = (baseUrlResults[parentBaseUrls] ?: 0) + resolved.size
        // Check before returning to Media3's addAll/copyOf callers. Each individual
        // allocation is already bounded by the incoming parent count above.
        if (total > MAX_BASE_URLS) unsupported()
        baseUrlResults[parentBaseUrls] = total
        if (resolved.size == parentBaseUrls.size) {
            // Relative BaseURLs return one result per parent, preserving parent order.
            resolved.forEachIndexed { index, child -> inherit(parentBaseUrls[index].url, child.url) }
        } else {
            // Absolute BaseURLs collapse all alternatives to one resource. Any stripped
            // ancestor taints that shared resource, including an absolute return to origin.
            for (child in resolved) for (parent in parentBaseUrls) inherit(parent.url, child.url)
        }
        return resolved
    }

    override fun buildSegmentTimelineElement(startTime: Long, duration: Long): SegmentBase.SegmentTimelineElement {
        if (++timelineElements > MAX_GRAPH_EDGES || duration <= 0) unsupported()
        return super.buildSegmentTimelineElement(startTime, duration)
    }

    private fun inherit(parent: String, child: String) {
        if (++registeredEdges > MAX_GRAPH_EDGES) unsupported()
        // Charge repeated parents as well as children, before parsing/graph retention.
        // Also charge normalized HTTP forms: escaping Unicode may lengthen a URI.
        reserveUris(parent, child)
        val from = parent.toHttpUrlOrNull()
        val to = child.toHttpUrlOrNull()
        from?.let { reserveUris(it.toString()) }
        to?.let { reserveUris(it.toString()) }
        if (credentials != null) {
            if (from == null || to == null) unsupported()
            credentials.inherit(from, to)
        }
    }

    private fun checkUriLength(value: String) {
        if (value.length > MAX_URI_CHARACTERS) unsupported()
    }

    private fun reserveUris(vararg values: String) {
        var count = 0L
        for (value in values) { checkUriLength(value); count += value.length }
        if (count > MAX_TOTAL_URI_CHARACTERS - uriCharacters) unsupported()
        uriCharacters += count
    }

    /** Reject unsupported constructs before Media3 can expand a timeline or discover
     * protection only after allocating representations. No URL or XML enters the error. */
    private fun preflight(document: ByteArray) {
        val parser = XmlPullParserFactory.newInstance().apply { isNamespaceAware = true }.newPullParser()
        parser.setInput(document.inputStream(), null)
        var elements = 0
        var representations = 0
        var longestRepresentationId = 4 // Media3 may render a missing ID as "null".
        val templates = mutableListOf<String>()
        var baseUrlTextLength = 0
        var baseUrlDepth = -1
        while (parser.eventType != XmlPullParser.END_DOCUMENT) {
            if (parser.eventType == XmlPullParser.DOCDECL) unsupported()
            if (parser.eventType == XmlPullParser.START_TAG) {
                if (baseUrlDepth >= 0) unsupported()
                if (++elements > MAX_GRAPH_EDGES || parser.depth > 64) unsupported()
                when (parser.name) {
                    "MPD" -> if (parser.getAttributeValue(null, "type")?.let { it != "static" } == true) unsupported()
                    "ContentProtection", "ContentSteering", "UTCTiming", "Location" -> unsupported()
                    "Representation" -> {
                        if (++representations > MAX_REPRESENTATIONS) unsupported()
                        longestRepresentationId = maxOf(longestRepresentationId, parser.getAttributeValue(null, "id")?.length ?: 4)
                    }
                    "BaseURL" -> { baseUrlTextLength = 0; baseUrlDepth = parser.depth }
                    "SegmentTemplate" -> {
                        listOf("media", "initialization").forEach { name ->
                            parser.getAttributeValue(null, name)?.let(templates::add)
                        }
                    }
                    "S" -> {
                        val duration = parser.getAttributeValue(null, "d")?.toLongOrNull()
                        val repeat = parser.getAttributeValue(null, "r")?.toLongOrNull() ?: 0
                        if (duration == null || duration <= 0 || repeat < -1 || repeat >= MAX_GRAPH_EDGES) unsupported()
                    }
                }
                for (attribute in 0 until parser.attributeCount) {
                    // ID substitution and direct URI references cannot start from unbounded
                    // attribute strings. This also bounds the inputs to template compilation.
                    checkUriLength(parser.getAttributeValue(attribute))
                    if (parser.getAttributeNamespace(attribute) == "http://www.w3.org/1999/xlink") unsupported()
                }
            }
            if (baseUrlDepth >= 0 && parser.eventType in listOf(XmlPullParser.TEXT, XmlPullParser.CDSECT, XmlPullParser.ENTITY_REF)) {
                baseUrlTextLength += parser.text?.length ?: 0
                if (baseUrlTextLength > MAX_URI_CHARACTERS) unsupported()
            }
            if (parser.eventType == XmlPullParser.END_TAG && parser.depth == baseUrlDepth) baseUrlDepth = -1
            parser.nextToken()
        }
        for (template in templates) {
            // Conservative upper bound, before Media3's String.format/StringBuilder.
            // Each numeric substitution needs at most 64 characters; IDs use the longest
            // representation in this manifest, including inherited templates.
            val idUses = template.windowed(18).count { it == "${'$'}RepresentationID${'$'}" }
            val upperBound = template.length.toLong() + idUses.toLong() * longestRepresentationId + template.count { it == '$' } * 64L
            if (upperBound > MAX_URI_CHARACTERS) unsupported()
            Regex("%0[^$]*").findAll(template).forEach { match ->
                val width = Regex("%0([0-9]+)[dxX]?").matchEntire(match.value)?.groupValues?.get(1)?.toIntOrNull()
                if (width == null || width !in 1..64) unsupported()
            }
        }
    }

    private fun unsupported(): Nothing = throw ParserException.createForMalformedManifest(
        "Unsupported DASH manifest.", YlBoundaryException(YlFailureKind.CONTAINER_UNSUPPORTED))

    companion object {
        private const val MAX_MANIFEST_BYTES = 2 * 1024 * 1024
        private const val MAX_REPRESENTATIONS = 4096
        private const val MAX_BASE_URLS = 128
        private const val MAX_GRAPH_EDGES = 100_000
        private const val MAX_URI_CHARACTERS = 8192
        private const val MAX_TOTAL_URI_CHARACTERS = 4L * 1024 * 1024
    }
}
