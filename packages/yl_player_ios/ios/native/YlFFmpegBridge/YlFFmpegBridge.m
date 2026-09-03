#import "YlFFmpegBridge.h"

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#include <libavcodec/codec_par.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

struct YLFPacket {
  AVPacket *value;
  struct YLFMediaContext *owner;
  struct YLFPacket *previous;
  struct YLFPacket *next;
};

struct YLFMediaContext {
  AVFormatContext *format;
  pthread_mutex_t mutex;
  atomic_bool cancelled;
  struct YLFPacket *packets;
};

static atomic_int_least32_t g_outstanding_packet_count = 0;

static int ylf_interrupt_callback(void *opaque) {
  struct YLFMediaContext *context = opaque;
  return context != NULL && atomic_load_explicit(&context->cancelled,
                                                  memory_order_relaxed);
}

static NSString *ylf_local_path(const char *url_or_path) {
  if (url_or_path == NULL) {
    return nil;
  }
  NSString *input = [NSString stringWithUTF8String:url_or_path];
  if (input.length == 0) {
    return nil;
  }
  if ([input hasPrefix:@"file://"]) {
    NSURL *url = [NSURL URLWithString:input];
    return url.isFileURL ? url.path : nil;
  }
  return [input isAbsolutePath] ? input : nil;
}

static int64_t ylf_timestamp_us(int64_t value, AVRational time_base) {
  if (value == AV_NOPTS_VALUE) {
    return INT64_MIN;
  }
  return av_rescale_q(value, time_base, AV_TIME_BASE_Q);
}

static int32_t ylf_stream_kind(enum AVMediaType media_type) {
  switch (media_type) {
  case AVMEDIA_TYPE_VIDEO:
    return YLFStreamVideo;
  case AVMEDIA_TYPE_AUDIO:
    return YLFStreamAudio;
  default:
    return YLFStreamUnknown;
  }
}

static int32_t ylf_codec(enum AVCodecID codec_id) {
  switch (codec_id) {
  case AV_CODEC_ID_H264:
    return YLFCodecH264;
  case AV_CODEC_ID_HEVC:
    return YLFCodecHEVC;
  case AV_CODEC_ID_AAC:
    return YLFCodecAAC;
  default:
    return YLFCodecUnsupported;
  }
}

static void ylf_unlink_packet(struct YLFPacket *packet) {
  struct YLFMediaContext *owner = packet->owner;
  if (packet->previous != NULL) {
    packet->previous->next = packet->next;
  } else if (owner != NULL) {
    owner->packets = packet->next;
  }
  if (packet->next != NULL) {
    packet->next->previous = packet->previous;
  }
  packet->owner = NULL;
  packet->previous = NULL;
  packet->next = NULL;
}

static void ylf_destroy_packet(struct YLFPacket *packet) {
  if (packet == NULL) {
    return;
  }
  av_packet_free(&packet->value);
  free(packet);
  atomic_fetch_sub_explicit(&g_outstanding_packet_count, 1,
                            memory_order_relaxed);
}

static uint16_t ylf_read_be16(const uint8_t *bytes) {
  return (uint16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
}

static OSStatus ylf_h264_format_description(
    const uint8_t *data,
    size_t size,
    CMVideoFormatDescriptionRef *out_description) {
  if (data == NULL || size < 7 || data[0] != 1) {
    return kCMFormatDescriptionError_InvalidParameter;
  }

  int nal_length_size = (data[4] & 0x03) + 1;
  const uint8_t *parameter_sets[512];
  size_t parameter_set_sizes[512];
  size_t parameter_set_count = 0;
  size_t offset = 6;
  uint8_t sps_count = data[5] & 0x1f;
  if (sps_count == 0) {
    return kCMFormatDescriptionError_InvalidParameter;
  }
  for (uint8_t index = 0; index < sps_count; index++) {
    if (offset + 2 > size) {
      return kCMFormatDescriptionError_InvalidParameter;
    }
    size_t length = ylf_read_be16(data + offset);
    offset += 2;
    if (length == 0 || offset + length > size) {
      return kCMFormatDescriptionError_InvalidParameter;
    }
    parameter_sets[parameter_set_count] = data + offset;
    parameter_set_sizes[parameter_set_count++] = length;
    offset += length;
  }
  if (offset >= size) {
    return kCMFormatDescriptionError_InvalidParameter;
  }
  uint8_t pps_count = data[offset++];
  if (pps_count == 0 || parameter_set_count + pps_count > 512) {
    return kCMFormatDescriptionError_InvalidParameter;
  }
  for (uint8_t index = 0; index < pps_count; index++) {
    if (offset + 2 > size) {
      return kCMFormatDescriptionError_InvalidParameter;
    }
    size_t length = ylf_read_be16(data + offset);
    offset += 2;
    if (length == 0 || offset + length > size) {
      return kCMFormatDescriptionError_InvalidParameter;
    }
    parameter_sets[parameter_set_count] = data + offset;
    parameter_set_sizes[parameter_set_count++] = length;
    offset += length;
  }
  return CMVideoFormatDescriptionCreateFromH264ParameterSets(
      kCFAllocatorDefault,
      parameter_set_count,
      parameter_sets,
      parameter_set_sizes,
      nal_length_size,
      out_description);
}

static OSStatus ylf_hevc_format_description(
    const uint8_t *data,
    size_t size,
    CMVideoFormatDescriptionRef *out_description) {
  if (data == NULL || size < 23 || data[0] != 1) {
    return kCMFormatDescriptionError_InvalidParameter;
  }

  int nal_length_size = (data[21] & 0x03) + 1;
  uint8_t array_count = data[22];
  const uint8_t *parameter_sets[512];
  size_t parameter_set_sizes[512];
  size_t parameter_set_count = 0;
  bool saw_vps = false;
  bool saw_sps = false;
  bool saw_pps = false;
  size_t offset = 23;

  for (uint8_t array_index = 0; array_index < array_count; array_index++) {
    if (offset + 3 > size) {
      return kCMFormatDescriptionError_InvalidParameter;
    }
    uint8_t nal_type = data[offset++] & 0x3f;
    uint16_t nal_count = ylf_read_be16(data + offset);
    offset += 2;
    for (uint16_t nal_index = 0; nal_index < nal_count; nal_index++) {
      if (offset + 2 > size) {
        return kCMFormatDescriptionError_InvalidParameter;
      }
      size_t length = ylf_read_be16(data + offset);
      offset += 2;
      if (length == 0 || offset + length > size) {
        return kCMFormatDescriptionError_InvalidParameter;
      }
      if (nal_type == 32 || nal_type == 33 || nal_type == 34) {
        if (parameter_set_count >= 512) {
          return kCMFormatDescriptionError_InvalidParameter;
        }
        parameter_sets[parameter_set_count] = data + offset;
        parameter_set_sizes[parameter_set_count++] = length;
        saw_vps |= nal_type == 32;
        saw_sps |= nal_type == 33;
        saw_pps |= nal_type == 34;
      }
      offset += length;
    }
  }
  if (!saw_vps || !saw_sps || !saw_pps) {
    return kCMFormatDescriptionError_InvalidParameter;
  }
  return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
      kCFAllocatorDefault,
      parameter_set_count,
      parameter_sets,
      parameter_set_sizes,
      nal_length_size,
      NULL,
      out_description);
}

static void ylf_free_packet_block(void *ref_con,
                                  void *doomed_memory_block,
                                  size_t size_in_bytes) {
  (void)doomed_memory_block;
  (void)size_in_bytes;
  ylf_destroy_packet((struct YLFPacket *)ref_con);
}

const char *ylf_build_configuration(void) {
  return avformat_configuration();
}

const char *ylf_ffmpeg_version(void) {
  return av_version_info();
}

int32_t ylf_open_local(const char *url_or_path,
                       YLFMediaContextRef *out_context,
                       YLFMediaInfo *out_info) {
  if (out_context == NULL || out_info == NULL) {
    return YLFResultInvalidArgument;
  }
  *out_context = NULL;
  memset(out_info, 0, sizeof(*out_info));

  NSString *path = ylf_local_path(url_or_path);
  if (path == nil) {
    return YLFResultInvalidArgument;
  }

  struct YLFMediaContext *context = calloc(1, sizeof(*context));
  if (context == NULL || pthread_mutex_init(&context->mutex, NULL) != 0) {
    free(context);
    return YLFResultOpenFailed;
  }
  atomic_init(&context->cancelled, false);
  context->format = avformat_alloc_context();
  if (context->format == NULL) {
    pthread_mutex_destroy(&context->mutex);
    free(context);
    return YLFResultOpenFailed;
  }
  context->format->interrupt_callback.callback = ylf_interrupt_callback;
  context->format->interrupt_callback.opaque = context;

  int result = avformat_open_input(&context->format,
                                   path.fileSystemRepresentation,
                                   NULL,
                                   NULL);
  if (result < 0) {
    avformat_free_context(context->format);
    pthread_mutex_destroy(&context->mutex);
    free(context);
    return YLFResultOpenFailed;
  }
  const char *format_name = context->format->iformat->name;
  if (format_name == NULL || strstr(format_name, "matroska") == NULL) {
    avformat_close_input(&context->format);
    pthread_mutex_destroy(&context->mutex);
    free(context);
    return YLFResultUnsupportedContainer;
  }
  if (avformat_find_stream_info(context->format, NULL) < 0) {
    avformat_close_input(&context->format);
    pthread_mutex_destroy(&context->mutex);
    free(context);
    return YLFResultOpenFailed;
  }

  out_info->stream_count = (int32_t)context->format->nb_streams;
  out_info->duration_us = context->format->duration == AV_NOPTS_VALUE
                              ? INT64_MIN
                              : context->format->duration;
  *out_context = context;
  return YLFResultOK;
}

int32_t ylf_copy_stream_info(YLFMediaContextRef context,
                             int32_t stream_index,
                             YLFStreamInfo *out_info) {
  if (context == NULL || out_info == NULL) {
    return YLFResultInvalidArgument;
  }
  if (stream_index < 0 || (unsigned int)stream_index >= context->format->nb_streams) {
    return YLFResultIndexOutOfRange;
  }
  AVStream *stream = context->format->streams[stream_index];
  AVCodecParameters *parameters = stream->codecpar;
  memset(out_info, 0, sizeof(*out_info));
  out_info->index = stream_index;
  out_info->kind = ylf_stream_kind(parameters->codec_type);
  out_info->codec = ylf_codec(parameters->codec_id);
  out_info->width = parameters->width;
  out_info->height = parameters->height;
  out_info->sample_rate = parameters->sample_rate;
  out_info->channel_count = parameters->ch_layout.nb_channels;
  out_info->duration_us = ylf_timestamp_us(stream->duration, stream->time_base);
  out_info->time_base_num = stream->time_base.num;
  out_info->time_base_den = stream->time_base.den;
  return YLFResultOK;
}

int32_t ylf_read_packet(YLFMediaContextRef context, YLFPacketRef *out_packet) {
  if (context == NULL || out_packet == NULL) {
    return YLFResultInvalidArgument;
  }
  *out_packet = NULL;
  if (atomic_load_explicit(&context->cancelled, memory_order_relaxed)) {
    return YLFResultCancelled;
  }

  pthread_mutex_lock(&context->mutex);
  if (atomic_load_explicit(&context->cancelled, memory_order_relaxed)) {
    pthread_mutex_unlock(&context->mutex);
    return YLFResultCancelled;
  }
  struct YLFPacket *packet = calloc(1, sizeof(*packet));
  if (packet == NULL) {
    pthread_mutex_unlock(&context->mutex);
    return YLFResultReadFailed;
  }
  packet->value = av_packet_alloc();
  if (packet->value == NULL) {
    free(packet);
    pthread_mutex_unlock(&context->mutex);
    return YLFResultReadFailed;
  }

  int result = av_read_frame(context->format, packet->value);
  if (result < 0) {
    av_packet_free(&packet->value);
    free(packet);
    pthread_mutex_unlock(&context->mutex);
    if (result == AVERROR_EOF) {
      return YLFResultEOF;
    }
    return atomic_load_explicit(&context->cancelled, memory_order_relaxed)
               ? YLFResultCancelled
               : YLFResultReadFailed;
  }

  packet->owner = context;
  packet->next = context->packets;
  if (context->packets != NULL) {
    context->packets->previous = packet;
  }
  context->packets = packet;
  atomic_fetch_add_explicit(&g_outstanding_packet_count, 1,
                            memory_order_relaxed);
  *out_packet = packet;
  pthread_mutex_unlock(&context->mutex);
  return YLFResultOK;
}

int32_t ylf_seek(YLFMediaContextRef context, int64_t position_us) {
  if (context == NULL || position_us < 0) {
    return YLFResultInvalidArgument;
  }
  pthread_mutex_lock(&context->mutex);
  int result = avformat_seek_file(context->format,
                                  -1,
                                  INT64_MIN,
                                  position_us,
                                  INT64_MAX,
                                  AVSEEK_FLAG_BACKWARD);
  if (result >= 0) {
    avformat_flush(context->format);
  }
  pthread_mutex_unlock(&context->mutex);
  return result >= 0 ? YLFResultOK : YLFResultSeekFailed;
}

void ylf_close(YLFMediaContextRef *context_pointer) {
  if (context_pointer == NULL || *context_pointer == NULL) {
    return;
  }
  struct YLFMediaContext *context = *context_pointer;
  *context_pointer = NULL;
  atomic_store_explicit(&context->cancelled, true, memory_order_relaxed);
  pthread_mutex_lock(&context->mutex);
  struct YLFPacket *packet = context->packets;
  context->packets = NULL;
  while (packet != NULL) {
    struct YLFPacket *next = packet->next;
    packet->owner = NULL;
    ylf_destroy_packet(packet);
    packet = next;
  }
  avformat_close_input(&context->format);
  pthread_mutex_unlock(&context->mutex);
  pthread_mutex_destroy(&context->mutex);
  free(context);
}

int32_t ylf_packet_stream_index(YLFPacketRef packet) {
  return packet == NULL || packet->value == NULL ? -1 : packet->value->stream_index;
}

int64_t ylf_packet_pts_us(YLFPacketRef packet) {
  if (packet == NULL || packet->value == NULL || packet->owner == NULL) {
    return INT64_MIN;
  }
  AVStream *stream = packet->owner->format->streams[packet->value->stream_index];
  return ylf_timestamp_us(packet->value->pts, stream->time_base);
}

int64_t ylf_packet_dts_us(YLFPacketRef packet) {
  if (packet == NULL || packet->value == NULL || packet->owner == NULL) {
    return INT64_MIN;
  }
  AVStream *stream = packet->owner->format->streams[packet->value->stream_index];
  return ylf_timestamp_us(packet->value->dts, stream->time_base);
}

int64_t ylf_packet_duration_us(YLFPacketRef packet) {
  if (packet == NULL || packet->value == NULL || packet->owner == NULL) {
    return 0;
  }
  AVStream *stream = packet->owner->format->streams[packet->value->stream_index];
  return av_rescale_q(packet->value->duration, stream->time_base, AV_TIME_BASE_Q);
}

size_t ylf_packet_size(YLFPacketRef packet) {
  return packet == NULL || packet->value == NULL ? 0 : (size_t)packet->value->size;
}

const uint8_t *ylf_packet_data(YLFPacketRef packet) {
  return packet == NULL || packet->value == NULL ? NULL : packet->value->data;
}

bool ylf_packet_is_keyframe(YLFPacketRef packet) {
  return packet != NULL && packet->value != NULL &&
         (packet->value->flags & AV_PKT_FLAG_KEY) != 0;
}

void ylf_packet_release(YLFPacketRef *packet_pointer) {
  if (packet_pointer == NULL || *packet_pointer == NULL) {
    return;
  }
  struct YLFPacket *packet = *packet_pointer;
  *packet_pointer = NULL;
  struct YLFMediaContext *owner = packet->owner;
  if (owner != NULL) {
    pthread_mutex_lock(&owner->mutex);
    ylf_unlink_packet(packet);
    pthread_mutex_unlock(&owner->mutex);
  }
  ylf_destroy_packet(packet);
}

int32_t ylf_debug_outstanding_packet_count(void) {
  return atomic_load_explicit(&g_outstanding_packet_count, memory_order_relaxed);
}

int32_t ylf_copy_video_format_description(
    YLFMediaContextRef context,
    int32_t stream_index,
    CMVideoFormatDescriptionRef *out_description) {
  if (context == NULL || out_description == NULL) {
    return YLFResultVideoConfigurationInvalid;
  }
  *out_description = NULL;
  if (stream_index < 0 ||
      (unsigned int)stream_index >= context->format->nb_streams) {
    return YLFResultVideoConfigurationInvalid;
  }
  AVCodecParameters *parameters =
      context->format->streams[stream_index]->codecpar;
  OSStatus status;
  switch (parameters->codec_id) {
  case AV_CODEC_ID_H264:
    status = ylf_h264_format_description(parameters->extradata,
                                         (size_t)parameters->extradata_size,
                                         out_description);
    break;
  case AV_CODEC_ID_HEVC:
    status = ylf_hevc_format_description(parameters->extradata,
                                         (size_t)parameters->extradata_size,
                                         out_description);
    break;
  default:
    return YLFResultVideoConfigurationInvalid;
  }
  return status == noErr ? YLFResultOK : YLFResultVideoConfigurationInvalid;
}

int32_t ylf_copy_video_format_description_from_codec_config(
    int32_t codec,
    const uint8_t *configuration,
    size_t configuration_size,
    CMVideoFormatDescriptionRef *out_description) {
  if (out_description == NULL) {
    return YLFResultVideoConfigurationInvalid;
  }
  *out_description = NULL;
  OSStatus status;
  switch (codec) {
  case YLFCodecH264:
    status = ylf_h264_format_description(configuration,
                                         configuration_size,
                                         out_description);
    break;
  case YLFCodecHEVC:
    status = ylf_hevc_format_description(configuration,
                                         configuration_size,
                                         out_description);
    break;
  default:
    return YLFResultVideoConfigurationInvalid;
  }
  return status == noErr ? YLFResultOK : YLFResultVideoConfigurationInvalid;
}

int32_t ylf_create_video_sample_buffer(
    YLFPacketRef *packet_pointer,
    CMVideoFormatDescriptionRef format_description,
    CMSampleBufferRef *out_sample_buffer) {
  if (packet_pointer == NULL || *packet_pointer == NULL ||
      format_description == NULL || out_sample_buffer == NULL) {
    return YLFResultInvalidArgument;
  }
  *out_sample_buffer = NULL;
  struct YLFPacket *packet = *packet_pointer;
  if (packet->value == NULL || packet->owner == NULL ||
      packet->value->size <= 0) {
    return YLFResultSampleBufferFailed;
  }

  AVStream *stream = packet->owner->format->streams[packet->value->stream_index];
  bool is_keyframe = (packet->value->flags & AV_PKT_FLAG_KEY) != 0;
  CMSampleTimingInfo timing = {
      .duration = packet->value->duration > 0
                      ? CMTimeMake(ylf_timestamp_us(packet->value->duration,
                                                    stream->time_base),
                                   AV_TIME_BASE)
                      : kCMTimeInvalid,
      .presentationTimeStamp = packet->value->pts == AV_NOPTS_VALUE
                                   ? kCMTimeInvalid
                                   : CMTimeMake(ylf_timestamp_us(packet->value->pts,
                                                                 stream->time_base),
                                                AV_TIME_BASE),
      .decodeTimeStamp = packet->value->dts == AV_NOPTS_VALUE
                             ? kCMTimeInvalid
                             : CMTimeMake(ylf_timestamp_us(packet->value->dts,
                                                           stream->time_base),
                                          AV_TIME_BASE),
  };
  size_t sample_size = (size_t)packet->value->size;
  CMBlockBufferCustomBlockSource source = {
      .version = kCMBlockBufferCustomBlockSourceVersion,
      .AllocateBlock = NULL,
      .FreeBlock = ylf_free_packet_block,
      .refCon = packet,
  };
  CMBlockBufferRef block_buffer = NULL;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault,
      packet->value->data,
      sample_size,
      kCFAllocatorNull,
      &source,
      0,
      sample_size,
      0,
      &block_buffer);
  if (status != noErr || block_buffer == NULL) {
    return YLFResultSampleBufferFailed;
  }

  struct YLFMediaContext *owner = packet->owner;
  pthread_mutex_lock(&owner->mutex);
  ylf_unlink_packet(packet);
  pthread_mutex_unlock(&owner->mutex);
  *packet_pointer = NULL;

  status = CMSampleBufferCreateReady(
      kCFAllocatorDefault,
      block_buffer,
      format_description,
      1,
      1,
      &timing,
      1,
      &sample_size,
      out_sample_buffer);
  CFRelease(block_buffer);
  if (status != noErr || *out_sample_buffer == NULL) {
    return YLFResultSampleBufferFailed;
  }

  if (!is_keyframe) {
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(*out_sample_buffer, true);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
      CFMutableDictionaryRef attachment =
          (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
      CFDictionarySetValue(attachment,
                           kCMSampleAttachmentKey_NotSync,
                           kCFBooleanTrue);
    }
  }
  return YLFResultOK;
}
