package dev.ylplayer.yl_player_android

import android.content.Context
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.hls.playlist.*
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.ParsingLoadable
import dev.ylplayer.yl_player_android.pigeon.*
import okhttp3.HttpUrl.Companion.toHttpUrl

internal fun requiresHlsCredentialAncestry(
    headers: Map<String, String>,
    credentials: Map<String, String>,
): Boolean = credentials.isNotEmpty() || headers.keys.any { name ->
    name.equals("Authorization", ignoreCase = true) ||
        name.equals("Cookie", ignoreCase = true) ||
        name.equals("Proxy-Authorization", ignoreCase = true)
}

/** One factory and provenance graph per source, retained through stop/restore/recovery. */
@OptIn(UnstableApi::class)
internal class YlMediaSourceFactory(source: AndroidSourceMessage, network: NetworkConfiguration, onRetry: (Int, Long) -> Unit) {
    private val managed = source.networkPolicy?.kind == AndroidNetworkPolicyKind.MANAGED
    private val requestHeaders = source.request?.headers.orEmpty()
    private val requestCredentials = source.request?.credentials.orEmpty()
    private val credentials = if (source.kind == AndroidSourceKind.NETWORK) YlOriginCredentialPolicy(
        source.locator.toHttpUrl(), requestHeaders, requestCredentials,
        requireKnownAncestry = source.format == AndroidMediaFormat.HLS || source.locator.toHttpUrl().encodedPath.lowercase().endsWith(".m3u8")) else null
    private val protectHlsCredentialAncestry =
        credentials != null && requiresHlsCredentialAncestry(requestHeaders, requestCredentials)
    private val http = credentials?.let { YlManagedHttpClient(it, if (managed) network else null, onRetry = onRetry) }
    private val loaderPolicy = if (managed) YlManagedLoadErrorPolicy() else DefaultLoadErrorHandlingPolicy()
    fun create(context: Context, item: MediaItem): MediaSource {
        val dataSources = if (http == null) DefaultDataSource.Factory(context)
            else DefaultDataSource.Factory(context, OkHttpDataSource.Factory(http))
        val hls = item.localConfiguration?.mimeType == "application/x-mpegURL" ||
            item.localConfiguration?.mimeType == "application/vnd.apple.mpegurl" ||
            item.localConfiguration?.uri?.path?.lowercase()?.endsWith(".m3u8") == true
        return if (hls) HlsMediaSource.Factory(dataSources)
            .setLoadErrorHandlingPolicy(loaderPolicy)
            .apply {
                if (protectHlsCredentialAncestry) {
                    setPlaylistParserFactory(YlOriginPlaylistParserFactory(checkNotNull(credentials)))
                }
            }
            .createMediaSource(item)
        else DefaultMediaSourceFactory(dataSources).setLoadErrorHandlingPolicy(loaderPolicy).createMediaSource(item)
    }
    fun cancelAll() { http?.cancelAll() }
    fun close() { http?.close() }
}

/** Media3 must surface terminal managed errors, never replay them via loader or HLS fallback. */
@OptIn(UnstableApi::class)
internal class YlManagedLoadErrorPolicy : DefaultLoadErrorHandlingPolicy(0) {
    override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo) = C.TIME_UNSET
    override fun getFallbackSelectionFor(fallbackOptions: LoadErrorHandlingPolicy.FallbackOptions, loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): LoadErrorHandlingPolicy.FallbackSelection? = null
}

/** Register the parser's fully resolved graph before any consumer can issue child requests.
 * The delegate retains Media3 variable substitution, key inheritance and LL-HLS semantics. */
@OptIn(UnstableApi::class)
internal class YlOriginPlaylistParserFactory(private val credentials: YlOriginCredentialPolicy) : HlsPlaylistParserFactory {
    private val delegate = DefaultHlsPlaylistParserFactory()
    override fun createPlaylistParser() = protect(delegate.createPlaylistParser())
    override fun createPlaylistParser(multivariantPlaylist: HlsMultivariantPlaylist, previousMediaPlaylist: HlsMediaPlaylist?) =
        protect(delegate.createPlaylistParser(multivariantPlaylist, previousMediaPlaylist))
    private fun protect(parser: ParsingLoadable.Parser<HlsPlaylist>) = ParsingLoadable.Parser<HlsPlaylist> { uri, input ->
        parser.parse(uri, input).also { playlist ->
            val parent = uri.toString().toHttpUrl()
            fun child(value: String?) { value?.let { parent.resolve(it) }?.let { credentials.inherit(parent, it) } }
            fun segment(value: HlsMediaPlaylist.SegmentBase) {
                child(value.url); child(value.fullSegmentEncryptionKeyUri)
                value.initializationSegment?.let { child(it.url); child(it.fullSegmentEncryptionKeyUri) }
            }
            when (playlist) {
                is HlsMultivariantPlaylist -> {
                    playlist.mediaPlaylistUrls.forEach { child(it.toString()) }
                    child(playlist.contentSteeringInfo?.serverUri?.toString())
                }
                is HlsMediaPlaylist -> {
                    playlist.segments.forEach { segment(it); it.parts.forEach(::segment) }
                    playlist.trailingParts.forEach(::segment)
                    playlist.lastSeenInitSegment?.let(::segment)
                    playlist.renditionReports.keys.forEach { child(it.toString()) }
                    playlist.interstitials.forEach { child(it.assetUri?.toString()); child(it.assetListUri?.toString()) }
                }
            }
        }
    }
}
