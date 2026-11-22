package dev.ylplayer.yl_player_android

import android.graphics.SurfaceTexture
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import java.nio.ByteBuffer
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** GPU readback runs on its own looper; the actual audio sink is read on the playback looper. */
internal class YlDashSurfaceProbe(private val playback: Handler, sampleAcrossOutput: Boolean = false) {
    private val thread = HandlerThread("dash-pixel-probe").apply { start() }
    private val gpu = Handler(thread.looper)

    private fun <T> onGpuThread(action: () -> T): T {
        val task = FutureTask(action)
        check(gpu.post(task))
        return task.get(5, TimeUnit.SECONDS)
    }

    private class Output(across: Boolean) {
        private val samples = if (across) 3 else 1
        val display = GlUtil.getDefaultEglDisplay()
        val context = GlUtil.createEglContext(display)
        private val eglSurface = GlUtil.createFocusedPlaceholderEglSurface(context, display)
        private val sampleTexture = GlUtil.createTexture(samples, samples, false)
        private val framebuffer = GlUtil.createFboForTexture(sampleTexture)
        private val decoderTexture = GlUtil.createExternalTexture()
        val texture = SurfaceTexture(decoderTexture)
        val surface = Surface(texture)
        private val pixel = ByteBuffer.allocateDirect(4 * samples * samples)
        private val transform = FloatArray(16)
        private val program = GlProgram(
            "attribute vec4 position; void main() { gl_Position = position; }",
            """
                #extension GL_OES_EGL_image_external : require
                precision mediump float;
                uniform samplerExternalOES frame;
                uniform mat4 transform;
                void main() { gl_FragColor = texture2D(frame, (transform * vec4(${if (across) "(gl_FragCoord.xy - 0.5) * 0.4 + 0.1" else "vec2(0.5)"}, 0.0, 1.0)).xy); }
            """.trimIndent(),
        )

        init {
            GlUtil.focusFramebuffer(display, context, eglSurface, framebuffer, samples, samples)
            program.setBufferAttribute("position", floatArrayOf(-1f, -1f, 3f, -1f, -1f, 3f), 2)
            program.setSamplerTexIdUniform("frame", decoderTexture, 0)
        }

        fun sample(): List<Int> {
            texture.updateTexImage()
            texture.getTransformMatrix(transform)
            program.use()
            program.setFloatsUniform("transform", transform)
            program.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, 3)
            pixel.clear()
            GLES20.glReadPixels(0, 0, samples, samples, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixel)
            GlUtil.checkGlError()
            val center = samples * samples / 2
            val rgb = (0..2).map { pixel.get(4 * center + it).toInt() and 255 }
            for (point in 0 until samples * samples) for (channel in 0..2) {
                val observed = pixel.get(4 * point + channel).toInt() and 255
                check(kotlin.math.abs(observed - rgb[channel]) < 32) { "Output grid point $point differs from centre $rgb" }
            }
            return rgb
        }

        fun close() {
            texture.setOnFrameAvailableListener(null)
            surface.release()
            texture.release()
            program.delete()
            GlUtil.deleteFbo(framebuffer)
            GlUtil.deleteTexture(sampleTexture)
            GlUtil.deleteTexture(decoderTexture)
            GlUtil.destroyEglSurface(display, eglSurface)
            GlUtil.destroyEglContext(display, context)
            GlUtil.terminate(display)
        }
    }

    private val output = try {
        onGpuThread { Output(sampleAcrossOutput) }
    } catch (failure: Exception) {
        thread.quitSafely()
        throw failure
    }
    val surface: Surface get() = output.surface
    val texture: SurfaceTexture get() = output.texture

    fun observe(onFrame: (Long, List<Int>, Long, Long) -> Unit, onError: (Throwable) -> Unit) {
        output.texture.setOnFrameAvailableListener({
            try {
                val gpuStartNs = System.nanoTime()
                val rgb = output.sample()
                val gpuEndNs = System.nanoTime()
                val timestamp = output.texture.timestamp
                check(playback.post {
                    try {
                        onFrame(timestamp, rgb, gpuStartNs, gpuEndNs)
                    } catch (error: Exception) {
                        onError(error)
                    }
                })
            } catch (error: Exception) {
                onError(error)
            }
        }, gpu)
    }

    fun drain() {
        onGpuThread { Unit }
        val barrier = FutureTask { Unit }
        check(playback.post(barrier))
        barrier.get(5, TimeUnit.SECONDS)
    }

    fun close() {
        try {
            onGpuThread { output.close() }
        } finally {
            thread.quitSafely()
            thread.join(5_000)
        }
    }
}
