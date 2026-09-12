#import "YlFFmpegBridge.h"

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

#include <pthread.h>
#include <stdatomic.h>
#include <errno.h>
#include <math.h>
#include <string.h>

#include <libavcodec/codec_par.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
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
  AVIOContext *avio;
  pthread_mutex_t mutex;
  atomic_bool cancelled;
  bool custom_io;
  bool cancel_sent;
  void *callback_opaque;
  YLFReadCallback read_callback;
  YLFSeekCallback seek_callback;
  YLFCancelCallback cancel_callback;
  int32_t callback_result;
  struct YLFPacket *packets;
};

static atomic_int_least32_t g_outstanding_packet_count = 0;

static int ylf_interrupt_callback(void *opaque) {
  struct YLFMediaContext *context = opaque;
  return context != NULL && atomic_load_explicit(&context->cancelled,
                                                  memory_order_relaxed);
}

static int ylf_avio_read(void *opaque, uint8_t *buffer, int capacity) {
  struct YLFMediaContext *context = opaque;
  if (context == NULL || context->read_callback == NULL || capacity <= 0) {
    return AVERROR(EINVAL);
  }
  if (atomic_load_explicit(&context->cancelled, memory_order_relaxed)) {
    context->callback_result = YLFCallbackCancelled;
    return AVERROR_EXIT;
  }
  context->callback_result = 0;
  int32_t result = context->read_callback(context->callback_opaque,
                                          buffer,
                                          (int32_t)capacity);
  if (result > 0) {
    return result <= capacity ? result : AVERROR(EIO);
  }
  if (result == 0) {
    return AVERROR_EOF;
  }
  context->callback_result = result;
  return result == YLFCallbackCancelled ? AVERROR_EXIT : AVERROR(EIO);
}

static int64_t ylf_avio_seek(void *opaque, int64_t offset, int whence) {
  struct YLFMediaContext *context = opaque;
  if (context == NULL || context->seek_callback == NULL) {
    return AVERROR(ENOSYS);
  }
  if (atomic_load_explicit(&context->cancelled, memory_order_relaxed)) {
    context->callback_result = YLFCallbackCancelled;
    return AVERROR_EXIT;
  }
  context->callback_result = 0;
  int64_t result = context->seek_callback(context->callback_opaque,
                                          offset,
                                          (int32_t)whence);
  if (result >= 0) {
    return result;
  }
  context->callback_result = (int32_t)result;
  if (result == YLFCallbackCancelled) {
    return AVERROR_EXIT;
  }
  return result == YLFCallbackSeekUnsupported ? AVERROR(ENOSYS) : AVERROR(EIO);
}

static void ylf_cancel_callbacks(struct YLFMediaContext *context) {
  if (context == NULL || !context->custom_io || context->cancel_sent) {
    return;
  }
  context->cancel_sent = true;
  if (context->cancel_callback != NULL) {
    context->cancel_callback(context->callback_opaque);
  }
}

static int32_t ylf_callback_failure(struct YLFMediaContext *context,
                                    int32_t fallback) {
  if (context == NULL) {
    return fallback;
  }
  switch (context->callback_result) {
  case YLFCallbackCancelled:
    return YLFResultCallbackCancelled;
  case YLFCallbackSeekUnsupported:
    return YLFResultCallbackSeekUnsupported;
  case YLFCallbackError:
    return YLFResultCallbackFailed;
  default:
    return fallback;
  }
}

static bool ylf_is_supported_input_format(const AVInputFormat *input_format) {
  if (input_format == NULL || input_format->name == NULL) {
    return false;
  }
  return strstr(input_format->name, "matroska") != NULL ||
         strstr(input_format->name, "flv") != NULL ||
         strstr(input_format->name, "mov") != NULL;
}

static int32_t ylf_discover_streams(struct YLFMediaContext *context,
                                    YLFMediaInfo *out_info) {
  if (!ylf_is_supported_input_format(context->format->iformat)) {
    return YLFResultUnsupportedContainer;
  }
  if (avformat_find_stream_info(context->format, NULL) < 0) {
    return ylf_callback_failure(context, YLFResultOpenFailed);
  }
  out_info->stream_count = (int32_t)context->format->nb_streams;
  out_info->duration_us = context->format->duration == AV_NOPTS_VALUE
                              ? INT64_MIN
                              : context->format->duration;
  return YLFResultOK;
}

static void ylf_destroy_context(struct YLFMediaContext *context) {
  if (context == NULL) {
    return;
  }
  atomic_store_explicit(&context->cancelled, true, memory_order_relaxed);
  ylf_cancel_callbacks(context);
  if (context->format != NULL) {
    avformat_close_input(&context->format);
  }
  if (context->avio != NULL) {
    avio_context_free(&context->avio);
  }
  pthread_mutex_destroy(&context->mutex);
  free(context);
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
  case AV_CODEC_ID_MP3:
    return YLFCodecMP3;
  case AV_CODEC_ID_DTS:
    return YLFCodecDTS;
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
  int32_t discovery_result = ylf_discover_streams(context, out_info);
  if (discovery_result != YLFResultOK) {
    ylf_destroy_context(context);
    return discovery_result;
  }
  *out_context = context;
  return YLFResultOK;
}

int32_t ylf_open_callbacks(void *opaque,
                           YLFReadCallback read_callback,
                           YLFSeekCallback seek_callback,
                           YLFCancelCallback cancel_callback,
                           YLFMediaContextRef *out_context,
                           YLFMediaInfo *out_info) {
  if (opaque == NULL || read_callback == NULL || out_context == NULL ||
      out_info == NULL) {
    return YLFResultInvalidArgument;
  }
  *out_context = NULL;
  memset(out_info, 0, sizeof(*out_info));

  struct YLFMediaContext *context = calloc(1, sizeof(*context));
  if (context == NULL || pthread_mutex_init(&context->mutex, NULL) != 0) {
    free(context);
    return YLFResultOpenFailed;
  }
  atomic_init(&context->cancelled, false);
  context->custom_io = true;
  context->callback_opaque = opaque;
  context->read_callback = read_callback;
  context->seek_callback = seek_callback;
  context->cancel_callback = cancel_callback;

  const int avio_buffer_size = 64 * 1024;
  uint8_t *avio_buffer = av_malloc((size_t)avio_buffer_size);
  if (avio_buffer == NULL) {
    ylf_destroy_context(context);
    return YLFResultOpenFailed;
  }
  context->avio = avio_alloc_context(avio_buffer,
                                     avio_buffer_size,
                                     0,
                                     context,
                                     ylf_avio_read,
                                     NULL,
                                     seek_callback == NULL ? NULL : ylf_avio_seek);
  if (context->avio == NULL) {
    av_free(avio_buffer);
    ylf_destroy_context(context);
    return YLFResultOpenFailed;
  }

  const AVInputFormat *input_format = NULL;
  int probe_result = av_probe_input_buffer2(context->avio,
                                            &input_format,
                                            NULL,
                                            NULL,
                                            0,
                                            1024 * 1024);
  if (probe_result < 0 || !ylf_is_supported_input_format(input_format)) {
    int32_t result = ylf_callback_failure(context,
                                          YLFResultUnsupportedContainer);
    ylf_destroy_context(context);
    return result;
  }

  context->format = avformat_alloc_context();
  if (context->format == NULL) {
    ylf_destroy_context(context);
    return YLFResultOpenFailed;
  }
  context->format->pb = context->avio;
  context->format->flags |= AVFMT_FLAG_CUSTOM_IO;
  context->format->interrupt_callback.callback = ylf_interrupt_callback;
  context->format->interrupt_callback.opaque = context;
  int open_result = avformat_open_input(&context->format,
                                        NULL,
                                        input_format,
                                        NULL);
  if (open_result < 0) {
    int32_t result = ylf_callback_failure(context, YLFResultOpenFailed);
    ylf_destroy_context(context);
    return result;
  }

  int32_t discovery_result = ylf_discover_streams(context, out_info);
  if (discovery_result != YLFResultOK) {
    ylf_destroy_context(context);
    return discovery_result;
  }
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

size_t ylf_stream_codec_config_size(YLFMediaContextRef context,
                                    int32_t stream_index) {
  if (context == NULL || stream_index < 0 ||
      (unsigned int)stream_index >= context->format->nb_streams) {
    return 0;
  }
  int size = context->format->streams[stream_index]->codecpar->extradata_size;
  return size > 0 ? (size_t)size : 0;
}

int32_t ylf_copy_stream_codec_config(YLFMediaContextRef context,
                                     int32_t stream_index,
                                     uint8_t *destination,
                                     size_t capacity) {
  size_t size = ylf_stream_codec_config_size(context, stream_index);
  if (size == 0 || destination == NULL || capacity < size) {
    return YLFResultInvalidArgument;
  }
  memcpy(destination,
         context->format->streams[stream_index]->codecpar->extradata,
         size);
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
    if (atomic_load_explicit(&context->cancelled, memory_order_relaxed)) {
      return context->custom_io ? YLFResultCallbackCancelled
                                : YLFResultCancelled;
    }
    return ylf_callback_failure(context, YLFResultReadFailed);
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
  return result >= 0 ? YLFResultOK
                     : ylf_callback_failure(context, YLFResultSeekFailed);
}

void ylf_close(YLFMediaContextRef *context_pointer) {
  if (context_pointer == NULL || *context_pointer == NULL) {
    return;
  }
  struct YLFMediaContext *context = *context_pointer;
  *context_pointer = NULL;
  atomic_store_explicit(&context->cancelled, true, memory_order_relaxed);
  ylf_cancel_callbacks(context);
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
  if (context->avio != NULL) {
    avio_context_free(&context->avio);
  }
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


bool ylf_mp4_requires_fallback(YLFMediaContextRef context) {
  if (!context || !context->format) return false;
  for (unsigned i = 0; i < context->format->nb_streams; i++) {
    AVCodecParameters *p = context->format->streams[i]->codecpar;
    if (p->codec_id == AV_CODEC_ID_DTS ||
        (p->codec_id == AV_CODEC_ID_HEVC && p->codec_tag == MKTAG('h','e','v','1'))) return true;
  }
  return false;
}

struct YLFDtsDecoder { AVCodecContext *codec; AVFrame *frame; AVPacket *packet; };
YLFDtsDecoderRef ylf_dts_create(void) {
  const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_DTS);
  if (!codec) return NULL;
  struct YLFDtsDecoder *d = calloc(1, sizeof(*d));
  if (!d) return NULL;
  d->codec = avcodec_alloc_context3(codec);
  d->frame = av_frame_alloc();
  d->packet = av_packet_alloc();
  if (!d->codec || !d->frame || !d->packet ||
      av_opt_set(d->codec->priv_data, "downmix", "stereo", 0) < 0 ||
      avcodec_open2(d->codec, codec, NULL) < 0) {
    ylf_dts_free(d); return NULL;
  }
  return d;
}
int32_t ylf_dts_decode(YLFDtsDecoderRef d, const uint8_t *data, size_t size,
    float *samples, int32_t capacity_frames, int32_t *out_frames, int32_t *out_sample_rate) {
  if (!d || !data || !size || size > INT_MAX || !samples || capacity_frames <= 0 ||
      !out_frames || !out_sample_rate) return YLFResultInvalidArgument;
  *out_frames = 0; *out_sample_rate = 0;
  av_packet_unref(d->packet);
  if (av_new_packet(d->packet, (int)size) < 0) return YLFResultReadFailed;
  memcpy(d->packet->data, data, size);
  int result = avcodec_send_packet(d->codec, d->packet);
  av_packet_unref(d->packet);
  if (result < 0) return YLFResultReadFailed;
  av_frame_unref(d->frame);
  result = avcodec_receive_frame(d->codec, d->frame);
  // dca has no delayed-output capability: each demuxed frame produces PCM.
  if (result < 0) return YLFResultReadFailed;
  AVFrame *f = d->frame;
  if (f->nb_samples <= 0 || f->nb_samples > capacity_frames || f->sample_rate <= 0 ||
      f->ch_layout.nb_channels < 1 || f->ch_layout.nb_channels > 8 ||
      (f->format != AV_SAMPLE_FMT_FLTP && f->format != AV_SAMPLE_FMT_S32P)) {
    av_frame_unref(f); return YLFResultReadFailed;
  }
  // The decoder uses embedded DTS downmix coefficients when supplied. Core
  // DTS without them retains its original layout; apply a normalized Lo/Ro
  // matrix using channel identities (never channel-count guesses). LFE is
  // excluded from stereo, matching the standard full-range stereo downmix.
  float matrix[8][2] = {{0}};
  float sum[2] = {0, 0};
  for (int c = 0; c < f->ch_layout.nb_channels; c++) {
    switch (av_channel_layout_channel_from_index(&f->ch_layout, c)) {
    case AV_CHAN_FRONT_LEFT: matrix[c][0] = 1; break;
    case AV_CHAN_FRONT_RIGHT: matrix[c][1] = 1; break;
    case AV_CHAN_FRONT_CENTER: matrix[c][0] = matrix[c][1] = 0.70710678f; break;
    case AV_CHAN_BACK_LEFT: case AV_CHAN_SIDE_LEFT: matrix[c][0] = 0.70710678f; break;
    case AV_CHAN_BACK_RIGHT: case AV_CHAN_SIDE_RIGHT: matrix[c][1] = 0.70710678f; break;
    case AV_CHAN_BACK_CENTER: matrix[c][0] = matrix[c][1] = 0.5f; break;
    case AV_CHAN_LOW_FREQUENCY: break;
    default: av_frame_unref(f); return YLFResultReadFailed;
    }
    sum[0] += matrix[c][0]; sum[1] += matrix[c][1];
  }
  float scale = 1.0f / fmaxf(1.0f, fmaxf(sum[0], sum[1]));
  memset(samples, 0, f->nb_samples * 2 * sizeof(float));
  for (int c = 0; c < f->ch_layout.nb_channels; c++) {
    for (int i = 0; i < f->nb_samples; i++) {
      float value = f->format == AV_SAMPLE_FMT_FLTP
        ? ((float *)f->extended_data[c])[i]
        : (float)(((int32_t *)f->extended_data[c])[i] / 2147483648.0);
      samples[2*i] += value * matrix[c][0] * scale;
      samples[2*i+1] += value * matrix[c][1] * scale;
    }
  }
  *out_frames = f->nb_samples; *out_sample_rate = f->sample_rate;
  av_frame_unref(f);
  return YLFResultOK;
}
void ylf_dts_reset(YLFDtsDecoderRef d) { if (d) avcodec_flush_buffers(d->codec); }
void ylf_dts_free(YLFDtsDecoderRef d) {
  if (!d) return;
  avcodec_free_context(&d->codec); av_frame_free(&d->frame); av_packet_free(&d->packet); free(d);
}
