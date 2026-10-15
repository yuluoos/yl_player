package dev.ylplayer.yl_player_android

import kotlin.test.*

class YlSoftwareDecodeBudgetTest {
    private val key = YlSoftwareDecodeKey("model", "os", "build", 1, 100, 8, 420, 320, 180, 24, 1, 1, 1)
    private val limits = YlSoftwareDecodeLimits(100, 2, 50, 1000, 500, 100)

    @Test fun unversionedMetadataNeverReachesAdmission() {
        assertFails { decodeStreamMetadata(0, longArrayOf(1, 1, 320, 180, 24000, 100, 31, 0, 0, 1000, 4000000)) }
    }

    @Test fun metadataRejectsWrongVersionLengthAndIntegerTruncation() {
        val valid = longArrayOf(1, 12, 320, 180, 24000, 0, 0, 0, 0, 1000, 4000000,
            2, 20, 24, 1, 8, 420, 1, 2, 2)
        assertEquals(YlNativeCodec.AV1, decodeStreamMetadata(0, valid).codec)
        assertEquals(24.0, decodeStreamMetadata(0, valid).frameRate)
        for (bad in listOf(valid.copyOf(19), valid.copyOf(21), valid.copyOf().also { it[11] = 1 },
            valid.copyOf().also { it[12] = 21 }, valid.copyOf().also { it[2] = Long.MAX_VALUE },
            valid.copyOf().also { it[1] = 1000 })) assertFails { decodeStreamMetadata(0, bad) }
    }

    @Test fun gapOrReversedCounterFailsAndClosedEmptyLeaseDoesNotConstrainNextOne() {
        for (bad in listOf(YlSoftwareDecodeObservation(1002, 101, 0, true),
            YlSoftwareDecodeObservation(1, 101, 0, true), YlSoftwareDecodeObservation(2, 99, 0, true))) {
            val pool = YlSoftwareDecodePool(); val first = YlSoftwareDecodeBudget(limits, pool)
            first.observe { YlSoftwareDecodeObservation(1, 100, 0, true) }
            assertFailsWith<YlBoundaryException> { first.observe { bad } }
            val next = YlSoftwareDecodeBudget(limits.copy(maxOwnedBytes = 200), pool)
            next.reserve(200, 1).close(); next.close(); first.close()
            assertEquals(0L, pool.ownedBytes)
        }
    }

    @Test fun exactIdentityAndPositiveRationalAreRequired() {
        val admission = YlSoftwareDecodeAdmission(mapOf(key to limits))
        assertEquals(limits, admission.limits(key))
        for (other in listOf(key.copy(model = "different"), key.copy(osBuild = "next"),
            key.copy(decoderBuild = "next"), key.copy(fpsNumerator = 0), key.copy(fpsDenominator = 0),
            key.copy(bitDepth = 10), key.copy(threads = 2))) assertNull(admission.limits(other))
        assertNull(YlSoftwareDecodeAdmission().limits(key))
    }
    @Test fun candidateAndRetainedOldFramesShareTheStrictestCap() {
        val pool = YlSoftwareDecodePool()
        val current = YlSoftwareDecodeBudget(limits, pool)
        val token = current.reserve(60, 1)
        current.close()
        val candidate = YlSoftwareDecodeBudget(limits, pool)
        assertFailsWith<YlBoundaryException> { candidate.reserve(60, 1) }
        assertEquals(60, pool.ownedBytes)
        token.close(); token.close(); assertEquals(0, pool.ownedBytes)
        candidate.close()
        val next = YlSoftwareDecodeBudget(limits, pool)
        next.reserve(100, 2).close(); next.close()
        assertEquals(0, pool.ownedBytes)
    }
    @Test fun invalidObservationAndOversizePacketPermanentlyCloseLease() {
        for (bad in listOf(YlSoftwareDecodeObservation(1, 0, 0, null),
            YlSoftwareDecodeObservation(-1, 0, 0, true), YlSoftwareDecodeObservation(1, -1, 0, true),
            YlSoftwareDecodeObservation(1, 0, 101, true))) {
            val budget = YlSoftwareDecodeBudget(limits, YlSoftwareDecodePool())
            assertFailsWith<YlBoundaryException> { budget.observe { bad } }
            assertFailsWith<YlBoundaryException> { budget.reserve(1, 0) }
            budget.close()
        }
        val budget = YlSoftwareDecodeBudget(limits, YlSoftwareDecodePool())
        assertFailsWith<YlBoundaryException> { budget.reservePacket(51) }
        assertFailsWith<YlBoundaryException> { budget.reserve(1, 0) }
        budget.close()
    }
    @Test fun replacementCannotEraseRecentCpuConsumption() {
        val pool = YlSoftwareDecodePool()
        val a = YlSoftwareDecodeBudget(limits, pool)
        a.observe { YlSoftwareDecodeObservation(1, 0, 0, true) }
        a.observe { YlSoftwareDecodeObservation(100, 400, 0, true) }; a.close()
        val b = YlSoftwareDecodeBudget(limits, pool)
        assertFailsWith<YlBoundaryException> { b.observe { YlSoftwareDecodeObservation(200, 501, 0, true) } }
        b.close()
    }
    @Test fun nativeReceiptsAreIdempotentAndSurviveRetirement() {
        val pool = YlSoftwareDecodePool(); val budget = YlSoftwareDecodeBudget(limits, pool)
        val id = budget.reserveNative(60, 1)
        assertTrue(id > 0); budget.close(); assertEquals(60, pool.ownedBytes)
        budget.releaseNative(id); budget.releaseNative(id)
        assertEquals(0, pool.ownedBytes)
        assertEquals(0L, budget.reserveNative(1, 0))
    }
}
