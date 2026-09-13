package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class YlFallbackRoutingPolicyTest {
    @Test
    fun `container and decoder failures route once to native fallback`() {
        val eligible = listOf(
            YlFailureKind.CONTAINER_UNSUPPORTED,
            YlFailureKind.DECODER_UNSUPPORTED,
            YlFailureKind.DECODER_UNAVAILABLE,
        )

        eligible.forEach { failure ->
            assertTrue(YlFallbackRoutingPolicy.shouldFallback(failure, fallbackAttempted = false))
            assertFalse(YlFallbackRoutingPolicy.shouldFallback(failure, fallbackAttempted = true))
        }
    }

    @Test
    fun `network source policy and resource failures never route to decoder fallback`() {
        val ineligible = listOf(
            YlFailureKind.NETWORK_FAILED,
            YlFailureKind.SOURCE_INVALID,
            YlFailureKind.SOURCE_MISSING,
            YlFailureKind.POLICY_UNSUPPORTED,
            YlFailureKind.RESOURCE_EXHAUSTED,
            YlFailureKind.PLATFORM_FAILURE,
        )

        ineligible.forEach { failure ->
            assertFalse(YlFallbackRoutingPolicy.shouldFallback(failure, fallbackAttempted = false))
        }
    }

    @Test
    fun `first frame timeout routes only with progressing input and video packets`() {
        assertTrue(
            YlFallbackRoutingPolicy.shouldFallbackFirstFrameTimeout(
                fallbackAttempted = false,
                inputProgressing = true,
                videoPacketsObserved = true,
            ),
        )
        assertFalse(
            YlFallbackRoutingPolicy.shouldFallbackFirstFrameTimeout(
                fallbackAttempted = false,
                inputProgressing = false,
                videoPacketsObserved = true,
            ),
        )
        assertFalse(
            YlFallbackRoutingPolicy.shouldFallbackFirstFrameTimeout(
                fallbackAttempted = false,
                inputProgressing = true,
                videoPacketsObserved = false,
            ),
        )
        assertFalse(
            YlFallbackRoutingPolicy.shouldFallbackFirstFrameTimeout(
                fallbackAttempted = true,
                inputProgressing = true,
                videoPacketsObserved = true,
            ),
        )
    }
}
