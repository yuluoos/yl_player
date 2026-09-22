package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import java.io.IOException
import java.io.FileNotFoundException
import java.net.UnknownHostException
import java.util.concurrent.CancellationException
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import org.mockito.Mockito
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

    @Test
    fun `dns failures are classified from bounded cause chain without leaking prose`() {
        val mapper = YlFailureMapper(YlSafeDiagnostics {})
        val secret = "private-host.example?token=secret"
        val direct = mapper.toMessage(UnknownHostException(secret))
        val wrapped = mapper.toMessage(IOException("wrapper", UnknownHostException(secret)))

        for (failure in listOf(direct, wrapped)) {
            assertEquals("network.dns_failed", failure.code)
            assertEquals("The media host could not be resolved. Check the network connection and source host configuration.", failure.message)
            assertTrue(failure.retryable)
            assertFalse(failure.message.contains(secret))
        }
        assertEquals("network.failed", mapper.toMessage(IOException("UnknownHostException: $secret")).code)
    }

    @Test
    fun `media playback preserves structured dns cause`() {
        assertEquals(YlFailureKind.NETWORK_DNS_FAILED, mediaFailure(
            errorCode = androidx.media3.common.PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
            cause = IOException("wrapper", UnknownHostException("secret")),
            decoderPolicy = AndroidDecoderPolicy.SYSTEM_DEFAULT,
        ))
    }

    @Test
    fun `explicit policy and cancellation classifications outrank nested network evidence`() {
        val mapper = YlFailureMapper(YlSafeDiagnostics {})
        val policy = IOException("wrapper", YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED))
        val cancelled = IOException("wrapper", CancellationException("cancelled"))
        assertEquals("policy.unsupported", mapper.toMessage(policy).code)
        assertEquals("load.cancelled", mapper.toMessage(cancelled).code)
    }

    @Test
    fun `media cancellation outranks competing dns evidence`() {
        val cancellation = CancellationException("cancelled").apply {
            initCause(UnknownHostException("private-host"))
        }
        assertEquals(YlFailureKind.LOAD_CANCELLED, mediaFailure(
            androidx.media3.common.PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
            cancellation,
            AndroidDecoderPolicy.SYSTEM_DEFAULT,
        ))
        assertEquals(YlFailureKind.LOAD_CANCELLED, mediaFailure(
            androidx.media3.common.PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
            IOException("wrapper", cancellation),
            AndroidDecoderPolicy.SYSTEM_DEFAULT,
        ))
    }

    @Test
    fun `structured http 403 crosses mapper media and Flutter boundaries without retry`() {
        val forbidden = invalidResponse(403)
        val mapper = YlFailureMapper(YlSafeDiagnostics {})
        val command = mapper.toMessage(forbidden, AndroidFailureScope.COMMAND)
        assertEquals("network.http_forbidden", command.code)
        assertEquals(AndroidFailureScope.COMMAND, command.scope)
        assertFalse(command.retryable)
        val bridged = mapper.toFlutterError(IOException("wrapper", forbidden), AndroidFailureScope.SESSION)
        val details = assertIs<AndroidFailureMessage>(bridged.details)
        assertEquals("network.http_forbidden", bridged.code)
        assertEquals(AndroidFailureScope.SESSION, details.scope)
        assertFalse(details.retryable)
        assertEquals(YlFailureKind.NETWORK_HTTP_FORBIDDEN, mediaFailure(
            androidx.media3.common.PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
            IOException("wrapper", forbidden), AndroidDecoderPolicy.SYSTEM_DEFAULT))
    }

    @Test
    fun `non 403 http status remains conservative`() {
        val response = invalidResponse(404)
        assertEquals("network.failed", YlFailureMapper(YlSafeDiagnostics {}).toMessage(response).code)
        assertEquals(YlFailureKind.NETWORK_FAILED, mediaFailure(
            androidx.media3.common.PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
            response, AndroidDecoderPolicy.SYSTEM_DEFAULT))
    }

    private fun invalidResponse(status: Int) = HttpDataSource.InvalidResponseCodeException(
        status, "private", null, emptyMap(), Mockito.mock(DataSpec::class.java), byteArrayOf())
}
