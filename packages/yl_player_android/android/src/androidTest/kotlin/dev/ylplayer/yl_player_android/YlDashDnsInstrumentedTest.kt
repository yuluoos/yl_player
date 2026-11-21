package dev.ylplayer.yl_player_android

import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.test.platform.app.InstrumentationRegistry
import java.net.Proxy
import java.net.UnknownHostException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import okhttp3.Dns
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class YlDashDnsInstrumentedTest {
    @Test fun unresolvedManifest() = checkDnsFailure(atSegment = false)
    @Test fun unresolvedSegment() = checkDnsFailure(atSegment = true)

    private fun checkDnsFailure(atSegment: Boolean) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val host = "yl-player-device-test.invalid"
        val failedLookups = CopyOnWriteArrayList<String>()
        val requestPaths = CopyOnWriteArrayList<String>()
        val transport = OkHttpClient.Builder().proxy(Proxy.NO_PROXY)
            .dns(object : Dns {
                override fun lookup(hostname: String): List<java.net.InetAddress> {
                    if (hostname != host) return Dns.SYSTEM.lookup(hostname)
                    failedLookups.add(hostname)
                    throw UnknownHostException(hostname)
                }
            })
            .addInterceptor { chain ->
                requestPaths.add(chain.request().url.encodedPath)
                chain.proceed(chain.request())
            }.build()
        MockWebServer().use { server ->
            val manifest = instrumentation.context.assets.open("manifest.mpd").bufferedReader().use { it.readText() }
            server.enqueue(MockResponse().setBody(manifest.replace("<BaseURL>period", "<BaseURL>https://$host/period")))
            val url = if (atSegment) server.url("/manifest.mpd") else "https://$host/manifest.mpd".toHttpUrl()
            val http = YlManagedHttpClient(
                YlOriginCredentialPolicy(url, emptyMap(), emptyMap()),
                NetworkConfiguration(5_000, 5_000, 0, 0, 0, 0), transport = transport,
            )
            val failure = CompletableFuture<PlaybackException>()
            var player: ExoPlayer? = null
            try {
                instrumentation.runOnMainSync {
                    player = ExoPlayer.Builder(instrumentation.targetContext).build().also { exo ->
                        exo.addListener(object : Player.Listener {
                            override fun onPlayerError(error: PlaybackException) { failure.complete(error) }
                        })
                        exo.setMediaSource(YlDashProgramMediaSource(
                            MediaItem.fromUri(url.toString()), OkHttpDataSource.Factory(http),
                            YlDashManifestParser(null), DefaultLoadErrorHandlingPolicy(0), YlDashGapGroups(),
                        ))
                        exo.prepare()
                        exo.play()
                    }
                }
                val publicFailure = YlFailureMapper().toMessage(failure.get(20, TimeUnit.SECONDS))
                assertEquals("network.dns_failed", publicFailure.code)
                assertFalse(publicFailure.message.contains(host))
                assertTrue(failedLookups.isNotEmpty())
                assertEquals(if (atSegment) 1 else 0, server.requestCount)
                assertEquals("/manifest.mpd", requestPaths.first())
                if (atSegment) assertTrue(requestPaths.any { it.endsWith(".m4s") })
            } finally {
                instrumentation.runOnMainSync { player?.release() }
                http.close()
            }
        }
    }
}
