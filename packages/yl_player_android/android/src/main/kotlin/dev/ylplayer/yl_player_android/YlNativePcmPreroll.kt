package dev.ylplayer.yl_player_android

/** Clip decoded interleaved S16 at programme time. Decoder preroll remains
 * available for references; only samples at/after the target reach AudioTrack. */
internal fun trimNativePcm(pcm: YlNativePcmChunk, targetUs: Long): YlNativePcmChunk? {
    if (pcm.sampleRate <= 0 || pcm.channelCount !in 1..2 || pcm.presentationTimeUs == Long.MIN_VALUE || targetUs < 0)
        throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
    val stride=pcm.channelCount*2
    if (pcm.data.size%stride != 0) throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
    if (pcm.presentationTimeUs >= targetUs) return pcm
    val delta = YlDashTime.of(targetUs,1_000_000)-YlDashTime.of(pcm.presentationTimeUs,1_000_000)
    val skip = delta.units(pcm.sampleRate.toLong(),true)
    if (skip >= pcm.data.size/stride) return null
    val pts = pcm.presentationTimeUs + YlDashTime.of(skip,pcm.sampleRate.toLong()).units(1_000_000,true)
    return pcm.copy(data=pcm.data.copyOfRange(skip.toInt()*stride,pcm.data.size),presentationTimeUs=pts)
}
