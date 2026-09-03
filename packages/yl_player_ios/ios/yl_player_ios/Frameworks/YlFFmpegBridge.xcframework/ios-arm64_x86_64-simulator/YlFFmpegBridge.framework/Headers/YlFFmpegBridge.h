#ifndef YL_FFMPEG_BRIDGE_H
#define YL_FFMPEG_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

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
} YLFStreamInfo;

// Accepts an absolute filesystem path or file:// URL. Returned contexts and
// packets are caller-owned. Closing a context invalidates and releases every
// packet that has not already been released.
YLF_EXPORT int32_t ylf_open_local(const char *url_or_path,
                                  YLFMediaContextRef *out_context,
                                  YLFMediaInfo *out_info);
YLF_EXPORT int32_t ylf_copy_stream_info(YLFMediaContextRef context,
                                        int32_t stream_index,
                                        YLFStreamInfo *out_info);
YLF_EXPORT int32_t ylf_read_packet(YLFMediaContextRef context,
                                   YLFPacketRef *out_packet);
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

// Test/diagnostic counter for FFmpeg packets currently owned by bridge
// contexts. It must return to zero after release or context close.
YLF_EXPORT int32_t ylf_debug_outstanding_packet_count(void);

#ifdef __cplusplus
}
#endif

#endif
