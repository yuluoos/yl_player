#ifndef YL_FFMPEG_BRIDGE_H
#define YL_FFMPEG_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <CoreMedia/CoreMedia.h>

#ifdef __cplusplus
extern "C" {
#endif

#if __has_attribute(visibility)
#define YLF_EXPORT __attribute__((visibility("default")))
#else
#define YLF_EXPORT
#endif

YLF_EXPORT const char *ylf_build_configuration(void);
YLF_EXPORT const char *ylf_ffmpeg_version(void);

typedef struct YLFMediaContext *YLFMediaContextRef;
typedef struct YLFPacket *YLFPacketRef;

enum {
  YLFResultOK = 0,
  YLFResultEOF = 1,
  YLFResultInvalidArgument = -1,
  YLFResultOpenFailed = -2,
  YLFResultUnsupportedContainer = -3,
  YLFResultReadFailed = -4,
  YLFResultCancelled = -5,
  YLFResultIndexOutOfRange = -6,
  YLFResultSeekFailed = -7,
  YLFResultVideoConfigurationInvalid = -8,
  YLFResultSampleBufferFailed = -9,
  YLFResultCallbackFailed = -10,
  YLFResultCallbackSeekUnsupported = -11,
  YLFResultCallbackCancelled = -12,
  YLFResultDolbyVisionUnsupported = -13,
  YLFResultAudioConfigurationUnsupported = -14,
};

enum {
  YLFCallbackError = -1,
  YLFCallbackCancelled = -2,
  YLFCallbackSeekUnsupported = -3,
};

enum {
  YLFStreamUnknown = 0,
  YLFStreamVideo = 1,
  YLFStreamAudio = 2,
};

enum {
  YLFCodecUnsupported = 0,
  YLFCodecH264 = 1,
  YLFCodecHEVC = 2,
  YLFCodecAAC = 3,
  YLFCodecMP3 = 4,
  YLFCodecDTS = 5,
  YLFCodecAC3 = 6,
  YLFCodecEAC3 = 7,
  YLFCodecFLAC = 8,
};

typedef struct {
  int32_t stream_count;
  int64_t duration_us;
} YLFMediaInfo;

typedef struct {
  int32_t index;
  int32_t kind;
  int32_t codec;
  int32_t width;
  int32_t height;
  int32_t sample_rate;
  int32_t channel_count;
  int64_t duration_us;
  int32_t time_base_num;
  int32_t time_base_den;
  // AVChannel native speaker-bit mask; zero when speaker roles are unspecified.
  uint64_t channel_layout_mask;
} YLFStreamInfo;

typedef int32_t (*YLFReadCallback)(void *opaque,
                                   uint8_t *buffer,
                                   int32_t capacity);
typedef int64_t (*YLFSeekCallback)(void *opaque,
                                   int64_t offset,
                                   int32_t whence);
typedef int64_t (*YLFTimeSeekCallback)(void *opaque,
                                      int64_t position_us);
typedef void (*YLFCancelCallback)(void *opaque);

// Accepts an absolute filesystem path or file:// URL. Returned contexts and
// packets are caller-owned. Closing a context invalidates and releases every
// packet that has not already been released.
YLF_EXPORT int32_t ylf_open_local(const char *url_or_path,
                                  YLFMediaContextRef *out_context,
                                  YLFMediaInfo *out_info);
// Opens a caller-owned synchronous byte source through FFmpeg custom AVIO.
// The opaque pointer and callbacks must remain valid until ylf_close returns.
// Read returns a positive byte count, zero for EOF, or a YLFCallback value.
YLF_EXPORT int32_t ylf_open_callbacks(void *opaque,
                                      YLFReadCallback read_callback,
                                      YLFSeekCallback seek_callback,
                                      YLFCancelCallback cancel_callback,
                                      YLFMediaContextRef *out_context,
                                      YLFMediaInfo *out_info);
YLF_EXPORT int32_t ylf_open_callbacks_with_time_seek(
    void *opaque,
    YLFReadCallback read_callback,
    YLFSeekCallback seek_callback,
    YLFTimeSeekCallback time_seek_callback,
    YLFCancelCallback cancel_callback,
    YLFMediaContextRef *out_context,
    YLFMediaInfo *out_info);
// DTS is decoded without encoders/resampling to stereo float PCM. Decode owns
// no caller memory; samples are interleaved L/R and capacity is stereo frames.
typedef struct YLFDtsDecoder *YLFDtsDecoderRef;
YLF_EXPORT bool ylf_mp4_requires_fallback(YLFMediaContextRef context);
YLF_EXPORT YLFDtsDecoderRef ylf_dts_create(void);
YLF_EXPORT int32_t ylf_dts_decode(YLFDtsDecoderRef decoder, const uint8_t *data,
    size_t size, float *samples, int32_t capacity_frames,
    int32_t *out_frames, int32_t *out_sample_rate);
YLF_EXPORT void ylf_dts_reset(YLFDtsDecoderRef decoder);
YLF_EXPORT void ylf_dts_free(YLFDtsDecoderRef decoder);

YLF_EXPORT int32_t ylf_copy_stream_info(YLFMediaContextRef context,
                                        int32_t stream_index,
                                        YLFStreamInfo *out_info);
YLF_EXPORT size_t ylf_stream_codec_config_size(YLFMediaContextRef context,
                                               int32_t stream_index);
YLF_EXPORT int32_t ylf_copy_stream_codec_config(YLFMediaContextRef context,
                                                int32_t stream_index,
                                                uint8_t *destination,
                                                size_t capacity);
YLF_EXPORT int32_t ylf_read_packet(YLFMediaContextRef context,
                                   YLFPacketRef *out_packet);
// Standalone MPEG-TS only: call before consuming packets; align packet/sample
// timestamps and subsequent seeks to format start_time. HLS callbacks rejected.
YLF_EXPORT int32_t ylf_use_relative_transport_stream_timestamps(YLFMediaContextRef context);

YLF_EXPORT int32_t ylf_seek(YLFMediaContextRef context, int64_t position_us);
YLF_EXPORT void ylf_close(YLFMediaContextRef *context);

YLF_EXPORT int32_t ylf_packet_stream_index(YLFPacketRef packet);
YLF_EXPORT int64_t ylf_packet_pts_us(YLFPacketRef packet);
YLF_EXPORT int64_t ylf_packet_dts_us(YLFPacketRef packet);
YLF_EXPORT int64_t ylf_packet_duration_us(YLFPacketRef packet);
YLF_EXPORT size_t ylf_packet_size(YLFPacketRef packet);
YLF_EXPORT const uint8_t *ylf_packet_data(YLFPacketRef packet);
YLF_EXPORT bool ylf_packet_is_keyframe(YLFPacketRef packet);
YLF_EXPORT void ylf_packet_release(YLFPacketRef *packet);

// FEL objects are independent of the demux context after creation. Calls on one
// object must be serialized. Any failed access unit invalidates RPU history;
// reset before feeding a new random-access sequence. Returned dictionaries and
// formats follow Create Rule; packets remain caller-owned.
typedef struct YLFFELContext *YLFFELContextRef;
YLF_EXPORT int32_t ylf_stream_dolby_vision_profile(YLFMediaContextRef context, int32_t stream_index);
YLF_EXPORT int32_t ylf_fel_create(YLFMediaContextRef context, int32_t stream_index, YLFFELContextRef *out_fel);
YLF_EXPORT int32_t ylf_fel_clone(YLFFELContextRef original, YLFFELContextRef *out_fel);
YLF_EXPORT int32_t ylf_fel_copy_base_format(YLFMediaContextRef context, int32_t stream_index, CMVideoFormatDescriptionRef *out_format);
YLF_EXPORT int32_t ylf_fel_copy_access_unit(YLFFELContextRef fel, YLFPacketRef packet, CFDictionaryRef *out_unit);
YLF_EXPORT void ylf_fel_reset(YLFFELContextRef fel);
YLF_EXPORT void ylf_fel_free(YLFFELContextRef fel);

// Test/diagnostic counter for FFmpeg packets currently owned by bridge
// contexts. It must return to zero after release or context close.
YLF_EXPORT int32_t ylf_debug_outstanding_packet_count(void);

// Create Rule: the caller owns returned Core Foundation objects. A successful
// sample-buffer creation consumes *packet and sets it to NULL. The packet bytes
// remain zero-copy and are released by CMBlockBuffer's destruction callback.
YLF_EXPORT int32_t ylf_copy_video_format_description(
    YLFMediaContextRef context,
    int32_t stream_index,
    CMVideoFormatDescriptionRef *out_description);
// Recovered in-band avcC/hvcC (or Annex B) configuration, combined with the
// original track's color/HDR/Dolby Vision metadata. Does not mutate the track.
// Dolby Vision currently accepts only Profile 5, levels 1-9, RPU+BL, no EL,
// compatibility ID 0 and uncompressed metadata. Recognized unsupported DV
// configurations return YLFResultDolbyVisionUnsupported; malformed metadata
// returns YLFResultVideoConfigurationInvalid. Neither falls back to plain HEVC.
YLF_EXPORT int32_t ylf_copy_video_format_description_with_codec_config(
    YLFMediaContextRef context,
    int32_t stream_index,
    const uint8_t *configuration,
    size_t configuration_size,
    CMVideoFormatDescriptionRef *out_description);
// Compatibility API: only codec configuration is available, so this function
// cannot preserve metadata from the original demuxed track.
YLF_EXPORT int32_t ylf_copy_video_format_description_from_codec_config(
    int32_t codec,
    const uint8_t *configuration,
    size_t configuration_size,
    CMVideoFormatDescriptionRef *out_description);
YLF_EXPORT int32_t ylf_create_video_sample_buffer(
    YLFPacketRef *packet,
    CMVideoFormatDescriptionRef format_description,
    CMSampleBufferRef *out_sample_buffer);

// Opus CELT only: mapping family 0, version 1, mono/stereo, 48 kHz float PCM.
// SILK/hybrid packets return AudioConfigurationUnsupported before consumption.
// This low-level decoder does not enable a player route. Callers supply the
// container's skip/discard metadata explicitly, exactly once. Reset clears
// history and pending skip; seek callers must decode preroll before presenting.
typedef struct YLFOpusDecoder *YLFOpusDecoderRef;
YLF_EXPORT YLFOpusDecoderRef ylf_opus_create(const uint8_t *head, size_t size);
// Interleaved output has the channel count from OpusHead. Capacity is in frames.
// Maximum input 64 KiB / 5760 frames (120 ms); skip <= 65535 samples.
// out_offset_frames advances the input packet PTS for leading trimmed samples.
// Successful zero-frame output means the packet was entirely trimmed.
// InvalidArgument / AudioConfigurationUnsupported preserve decoder state.
// ReadFailed requires reset before reuse; output is unspecified on failure.
YLF_EXPORT int32_t ylf_opus_decode(YLFOpusDecoderRef decoder,
    const uint8_t *data, size_t size, uint32_t skip, uint32_t discard,
    float *samples, int32_t capacity_frames, int32_t *out_frames,
    int32_t *out_offset_frames);
YLF_EXPORT void ylf_opus_reset(YLFOpusDecoderRef decoder);
YLF_EXPORT void ylf_opus_free(YLFOpusDecoderRef decoder);

#ifdef __cplusplus
}
#endif

#endif
