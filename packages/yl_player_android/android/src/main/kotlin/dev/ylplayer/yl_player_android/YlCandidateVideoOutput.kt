package dev.ylplayer.yl_player_android

import android.content.Context
import android.view.Surface
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.video.PlaceholderSurface

/** Worker-owned private Surface/SurfaceTexture, never registered with Flutter. PlaceholderSurface
 * owns its EGL/SurfaceTexture thread. Its potentially waiting construction occurs off main.
 * The owner must obtain a successful Media3 detach acknowledgement before releasing this object.
 */
internal interface YlPrivateVideoOutput {
    val surface: Surface
    val identity: YlOutputIdentity
    fun releaseAfterAcknowledgedDetach()
}

@OptIn(UnstableApi::class)
internal class YlCandidateVideoOutput(context: Context) : YlPrivateVideoOutput {
    override val surface: Surface = PlaceholderSurface.newInstance(context, false)
    override val identity = YlOutputIdentity(0, false)
    private var released = false
    override fun releaseAfterAcknowledgedDetach() {
        if (released) return
        released = true
        surface.release()
    }
}

/** Worker-side borrow bookkeeping. A failed/timeout detach leaves both resources retained. */
internal class YlEngineVideoOutput(private val candidate: YlPrivateVideoOutput) {
    private var surface: Surface? = candidate.surface
    private var identity = candidate.identity
    private var renderSurface: Surface? = candidate.surface
    private var candidateAttached = true
    var surfaceRebuildCount = 0
        private set
    fun attach(expected: Long, current: Long, consumer: (Surface) -> Unit): Boolean {
        if (expected != current) return false
        surface?.let { consumer(it); renderSurface = it }
        return surface != null
    }
    fun switchTo(output: Surface, identity: YlOutputIdentity, acknowledgedAttach: (Surface) -> Unit) {
        acknowledgedAttach(output)
        surface = output
        renderSurface = output
        this.identity = identity
        if (candidateAttached) {
            candidateAttached = false
            candidate.releaseAfterAcknowledgedDetach()
        }
    }
    fun detach(clear: (Surface) -> Unit) {
        surface?.let { clear(it); renderSurface = null }
    }
    fun recordRebuild() { surfaceRebuildCount++ }
    fun renderedIdentity(output: Any): YlOutputIdentity? = identity.takeIf { output === renderSurface }
    fun firstFrameEvent(output: Any, occurredAtMs: Long): YlEngineEvent.FirstFrame? {
        val outputIdentity = renderedIdentity(output) ?: return null
        // This is eligibility only. Main may reject this observation after a generation change;
        // only the authoritative reducer may consume the once-per-session milestone.
        if (!outputIdentity.isPublic) return null
        return YlEngineEvent.FirstFrame(outputIdentity, occurredAtMs)
    }
    fun dispose(clear: (Surface) -> Unit) {
        surface?.let(clear)
        surface = null
        renderSurface = null
        if (candidateAttached) { candidateAttached = false; candidate.releaseAfterAcknowledgedDetach() }
    }
}
