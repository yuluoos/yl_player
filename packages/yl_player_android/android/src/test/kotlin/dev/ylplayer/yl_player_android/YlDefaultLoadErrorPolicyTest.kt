package dev.ylplayer.yl_player_android

import androidx.media3.common.C
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import org.mockito.Mockito.mock

class YlDefaultLoadErrorPolicyTest {
    @Test fun `terminal HTTP denial skips retries and transient errors keep Media3 delay`() {
        val policy = YlDefaultLoadErrorPolicy()
        fun error(status: Int) = LoadErrorHandlingPolicy.LoadErrorInfo(
            mock(LoadEventInfo::class.java), MediaLoadData(C.DATA_TYPE_MANIFEST),
            IOException(YlHttpStatusException(status)), 2,
        )
        assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(error(403)))
        val transient = error(503)
        assertEquals(DefaultLoadErrorHandlingPolicy().getRetryDelayMsFor(transient), policy.getRetryDelayMsFor(transient))
    }
}
