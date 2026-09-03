#import "YlFFmpegBridge.h"

#import <Foundation/Foundation.h>

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
