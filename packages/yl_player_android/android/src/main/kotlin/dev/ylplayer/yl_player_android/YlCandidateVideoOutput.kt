package dev.ylplayer.yl_player_android

import android.content.Context
import android.view.Surface
import android.os.SystemClock
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
    val isProtected: Boolean get() = false
    fun releaseAfterAcknowledgedDetach()
}

@OptIn(UnstableApi::class)
internal class YlCandidateVideoOutput(context: Context, override val isProtected: Boolean = false) : YlPrivateVideoOutput {
    override val surface: Surface = if (isProtected && !PlaceholderSurface.isSecureSupported(context)) {
        throw YlBoundaryException(YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
    } else PlaceholderSurface.newInstance(context, isProtected)
    override val identity = YlOutputIdentity(0, false)
    private var released = false
    override fun releaseAfterAcknowledgedDetach() {
        if (released) return
        released = true
        surface.release()
    }
}

/** Worker-side borrow bookkeeping. A failed/timeout detach leaves both resources retained. */
internal class YlEngineVideoOutput(private val candidate: YlPrivateVideoOutput, private val retainCandidate: Boolean = false) {
    val isProtected get() = candidate.isProtected
    private var surface: Surface? = candidate.surface
    private var identity = candidate.identity
    private var renderSurface: Surface? = candidate.surface
    private var candidateAttached = true
    private var protectedFrameFenceMs = Long.MIN_VALUE
    private var inspection: YlPrivateVideoOutput? = null
    var surfaceRebuildCount = 0
        private set
    fun attach(expected: Long, current: Long, consumer: (Surface) -> Unit): Boolean {
        if (expected != current) return false
        (inspection?.surface ?: surface)?.let { consumer(it); renderSurface = it }
        return surface != null
    }
    fun beginInspection(output: YlPrivateVideoOutput, acknowledgedAttach: (Surface) -> Unit) {
        if (candidate.isProtected && !output.isProtected) throw YlBoundaryException(YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
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
    fun switchTo(output: Surface, identity: YlOutputIdentity, acknowledgedAttach: (Surface) -> Unit) =
        switchTo(output, identity, acknowledgedAttach, false)
    fun switchTo(output: Surface, identity: YlOutputIdentity, acknowledgedAttach: (Surface) -> Unit, protected: Boolean) {
        if (candidate.isProtected && !protected) throw YlBoundaryException(YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
        if (candidate.isProtected) {
            // Stop producing frames on the old holder before recording a render-time fence.
            // Waiting one millisecond on the worker avoids ambiguous equal-ms callbacks.
            parkProtected(acknowledgedAttach)
            protectedFrameFenceMs = SystemClock.elapsedRealtime()
            SystemClock.sleep(1)
        }
        acknowledgedAttach(output)
        surface = output
        renderSurface = output
        this.identity = identity
        inspection?.releaseAfterAcknowledgedDetach()
        inspection = null
        if (candidateAttached && !candidate.isProtected && !retainCandidate) {
            candidateAttached = false
            candidate.releaseAfterAcknowledgedDetach()
        }
    }
    fun parkNative(acknowledgedAttach: (Surface) -> Unit) {
        check(retainCandidate && !candidate.isProtected)
        acknowledgedAttach(candidate.surface)
        surface = candidate.surface; renderSurface = candidate.surface; identity = candidate.identity
    }
    fun parkProtected(acknowledgedAttach: (Surface) -> Unit) {
        check(candidate.isProtected)
        acknowledgedAttach(candidate.surface)
        surface = candidate.surface; renderSurface = candidate.surface; identity = candidate.identity
        inspection?.releaseAfterAcknowledgedDetach(); inspection = null
    }
    fun detach(clear: (Surface) -> Unit) {
        renderSurface?.let { clear(it); renderSurface = null }
    }
    fun installReplacement(output: Surface, identity: YlOutputIdentity, active: Boolean, acknowledgedAttach: (Surface) -> Unit): Boolean {
        if (candidate.isProtected) throw YlBoundaryException(YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
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
        if (candidate.isProtected && occurredAtMs <= protectedFrameFenceMs) return null
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
