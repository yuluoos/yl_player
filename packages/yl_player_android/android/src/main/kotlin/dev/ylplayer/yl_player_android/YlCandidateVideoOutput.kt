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
    private var inspection: YlPrivateVideoOutput? = null
    var surfaceRebuildCount = 0
        private set
    fun attach(expected: Long, current: Long, consumer: (Surface) -> Unit): Boolean {
        if (expected != current) return false
        (inspection?.surface ?: surface)?.let { consumer(it); renderSurface = it }
        return surface != null
    }
    fun beginInspection(output: YlPrivateVideoOutput, acknowledgedAttach: (Surface) -> Unit) {
        check(inspection == null)
        // Retain the new output even on an unacknowledged attach; disposal owns safe cleanup.
        inspection = output
        acknowledgedAttach(output.surface)
        renderSurface = output.surface
    }
    fun finishInspection(acknowledgedAttach: (Surface) -> Unit) {
        val pending = inspection ?: return
        surface?.let { acknowledgedAttach(it); renderSurface = it }
        inspection = null
        pending.releaseAfterAcknowledgedDetach()
    }
    fun switchTo(output: Surface, identity: YlOutputIdentity, acknowledgedAttach: (Surface) -> Unit) {
        acknowledgedAttach(output)
        surface = output
        renderSurface = output
        this.identity = identity
        inspection?.releaseAfterAcknowledgedDetach()
        inspection = null
        if (candidateAttached) {
            candidateAttached = false
            candidate.releaseAfterAcknowledgedDetach()
        }
    }
    fun detach(clear: (Surface) -> Unit) {
        renderSurface?.let { clear(it); renderSurface = null }
    }
    fun installReplacement(output: Surface, identity: YlOutputIdentity, active: Boolean, acknowledgedAttach: (Surface) -> Unit): Boolean {
        val pending = inspection
        if (pending != null) {
            // A main-owned public wrapper can change during an evidence wait. Keep rendering
            // private, while retaining the replacement for the eventual proven handoff.
            surface = output
            this.identity = identity
            if (active) { acknowledgedAttach(pending.surface); renderSurface = pending.surface }
        } else if (active) {
            switchTo(output, identity, acknowledgedAttach)
        } else {
            // Background can run between main's detach/recreate and this worker install.
            // Main retires the old wrapper after acknowledgement, so update retention even idle.
            check(renderSurface == null) { "Replacement requires acknowledged detachment" }
            surface = output
            this.identity = identity
            if (candidateAttached) {
                candidateAttached = false
                candidate.releaseAfterAcknowledgedDetach()
            }
        }
        recordRebuild()
        return true
    }
    fun recordRebuild() { surfaceRebuildCount++ }
    fun renderedIdentity(output: Any): YlOutputIdentity? = if (output !== renderSurface) null else inspection?.identity ?: identity
    fun firstFrameEvent(output: Any, occurredAtMs: Long): YlEngineEvent.FirstFrame? {
        val outputIdentity = renderedIdentity(output) ?: return null
        // This is eligibility only. Main may reject this observation after a generation change;
        // only the authoritative reducer may consume the once-per-session milestone.
        if (!outputIdentity.isPublic) return null
        return YlEngineEvent.FirstFrame(outputIdentity, occurredAtMs)
    }
    fun dispose(clear: (Surface) -> Unit) {
        renderSurface?.let(clear)
        inspection?.releaseAfterAcknowledgedDetach()
        inspection = null
        surface = null
        renderSurface = null
        if (candidateAttached) { candidateAttached = false; candidate.releaseAfterAcknowledgedDetach() }
    }
}
