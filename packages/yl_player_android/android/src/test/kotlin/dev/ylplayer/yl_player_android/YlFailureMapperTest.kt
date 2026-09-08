package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import java.io.IOException
import java.io.FileNotFoundException
import java.util.concurrent.CancellationException
import kotlin.test.*

class YlFailureMapperTest {
    @Test
    fun `public failures and local diagnostics never contain untrusted exception prose`() {
        val lines = mutableListOf<String>()
        val mapper = YlFailureMapper(YlSafeDiagnostics(lines::add))
        val secret = "https://user:password@example.test/video?token=secret Authorization: Bearer abc Cookie: session=xyz\n at Secret.frame(Secret.kt:12)"
        for (error in listOf(IOException(secret), IllegalStateException(secret))) {
            val mapped = mapper.toFlutterError(error)
            val details = assertIs<AndroidFailureMessage>(mapped.details)
            assertTrue(details.diagnosticId.isNotBlank())
            assertEquals(details.code, mapped.code)
            assertEquals(details.message, mapped.message)
            for (value in listOf(mapped.toString(), details.toString(), lines.last())) {
                for (forbidden in listOf("https:", "example.test", "Authorization", "Cookie", "secret", "abc", "xyz", "Secret.frame")) {
                    assertFalse(value.contains(forbidden), value)
                }
            }
            assertTrue(lines.last().contains(error.javaClass.simpleName))
            assertTrue(lines.last().contains(details.diagnosticId))
            assertFalse(lines.last().contains('\n'))
        }
        assertEquals(2, lines.size)
        assertEquals("The network request failed.", mapper.toFlutterError(IOException("different")).message)
        assertEquals("An internal player failure occurred.", mapper.toFlutterError(IllegalStateException("different")).message)
    }

    @Test
    fun `known failures have stable codes and unknown FlutterErrors cannot bypass sanitization`() {
        val mapper = YlFailureMapper(YlSafeDiagnostics {})
        val cases = listOf(
            YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED) to "policy.unsupported",
            YlBoundaryException(YlFailureKind.SOURCE_INVALID) to "source.invalid",
            FileNotFoundException("private") to "source.missing",
            IOException("private") to "network.failed",
            YlBoundaryException(YlFailureKind.CONTAINER_UNSUPPORTED) to "container.unsupported",
            YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE) to "decoder.unavailable",
            OutOfMemoryError("private") to "resource.exhausted",
            CancellationException("private") to "load.cancelled",
            FlutterError("unsafe", "https://secret", "Cookie: abc") to "internal.failure",
        )
        for ((error, code) in cases) {
            assertEquals(code, mapper.toFlutterError(error).code)
        }
    }

    @Test
    fun `logging failure cannot escape the safe boundary`() {
        val mapper = YlFailureMapper(YlSafeDiagnostics { throw IOException("secret") })
        assertEquals("internal.failure", mapper.toFlutterError(IllegalStateException("secret")).code)
    }
}
