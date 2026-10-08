#include <opus/opus.h>
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
#include <libavutil/intreadwrite.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mastering_display_metadata.h>

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
  YLFTimeSeekCallback time_seek_callback;
  YLFCancelCallback cancel_callback;
  int32_t callback_result;
  int64_t timeline_origin_us;
  bool relative_transport_stream_timeline;
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
  return strcmp(input_format->name, "avi") == 0 ||
         strstr(input_format->name, "matroska") != NULL ||
         strstr(input_format->name, "flv") != NULL ||
         strstr(input_format->name, "mov") != NULL ||
         strstr(input_format->name, "mpegts") != NULL;
}

static int32_t ylf_reset_after_annexb_probe(
    struct YLFMediaContext *context) {
  if (context->time_seek_callback != NULL) {
    int64_t result = context->time_seek_callback(context->callback_opaque, 0);
    if (result < 0) {
      context->callback_result = (int32_t)result;
      return ylf_callback_failure(context, YLFResultSeekFailed);
    }
    context->avio->buf_ptr = context->avio->buf_end;
    context->avio->eof_reached = 0;
    context->avio->error = 0;
    context->avio->pos = 0;
    avformat_flush(context->format);
    return YLFResultOK;
  }
  if (avformat_seek_file(context->format, -1, INT64_MIN, 0, INT64_MAX,
                         AVSEEK_FLAG_BACKWARD) < 0) {
    return YLFResultSeekFailed;
  }
  avformat_flush(context->format);
  return YLFResultOK;
}

static bool ylf_prime_aac_from_adts(AVCodecParameters *parameters,
                                    const uint8_t *data,
                                    size_t size) {
  if (parameters == NULL || data == NULL || size < 7 ||
      data[0] != 0xff || (data[1] & 0xf6) != 0xf0) {
    return false;
  }
  int object_type = ((data[2] >> 6) & 0x03) + 1;
  int frequency_index = (data[2] >> 2) & 0x0f;
  int channel_configuration = ((data[2] & 0x01) << 2) | (data[3] >> 6);
  static const int sample_rates[] = {
      96000, 88200, 64000, 48000, 44100, 32000, 24000,
      22050, 16000, 12000, 11025, 8000, 7350,
  };
  if (object_type != 2 || frequency_index >= 13 ||
      channel_configuration < 1 || channel_configuration > 7) {
    return false;
  }
  if (parameters->extradata_size == 0) {
    parameters->extradata = av_mallocz(2 + AV_INPUT_BUFFER_PADDING_SIZE);
    if (parameters->extradata == NULL) return false;
    parameters->extradata[0] = (uint8_t)((object_type << 3) |
                                         (frequency_index >> 1));
    parameters->extradata[1] = (uint8_t)(((frequency_index & 1) << 7) |
                                         (channel_configuration << 3));
    parameters->extradata_size = 2;
  }
  parameters->sample_rate = sample_rates[frequency_index];
  if (parameters->ch_layout.nb_channels == 0) {
    av_channel_layout_uninit(&parameters->ch_layout);
    av_channel_layout_default(&parameters->ch_layout, channel_configuration);
  }
  return true;
}

static bool ylf_annexb_needs_metadata(AVFormatContext *format) {
  for (unsigned int index = 0; index < format->nb_streams; index++) {
    AVCodecParameters *parameters = format->streams[index]->codecpar;
    if (parameters->codec_type == AVMEDIA_TYPE_VIDEO &&
        (parameters->codec_id == AV_CODEC_ID_H264 ||
         parameters->codec_id == AV_CODEC_ID_HEVC) &&
        parameters->extradata_size == 0) {
      return true;
    }
    if (parameters->codec_type == AVMEDIA_TYPE_AUDIO &&
        parameters->codec_id == AV_CODEC_ID_AAC &&
        (parameters->extradata_size == 0 || parameters->sample_rate <= 0 ||
         parameters->ch_layout.nb_channels <= 0)) {
      return true;
    }
  }
  return false;
}

static int32_t ylf_prime_annexb_video_config(
    struct YLFMediaContext *context) {
  const char *name = context->format->iformat ? context->format->iformat->name : NULL;
  bool is_avi = name != NULL && strcmp(name, "avi") == 0;
  if (name == NULL || (!is_avi && strstr(name, "mpegts") == NULL)) {
    return YLFResultOK;
  }
  bool needs_metadata = ylf_annexb_needs_metadata(context->format);
  if (!needs_metadata) return YLFResultOK;

  AVPacket *packet = av_packet_alloc();
  if (packet == NULL) return YLFResultOpenFailed;
  bool read_any = false;
  int64_t scanned_bytes = 0;
  for (int attempt = 0; attempt < 512 && needs_metadata; attempt++) {
    av_packet_unref(packet);
    int result = av_read_frame(context->format, packet);
    if (result < 0) break;
    read_any = true;
    scanned_bytes += FFMAX(packet->size, 0);
    if (is_avi && scanned_bytes > 8 * 1024 * 1024) break;
    if (packet->stream_index < 0 ||
        (unsigned int)packet->stream_index >= context->format->nb_streams ||
        packet->size <= 4 || packet->data == NULL) {
      continue;
    }
    AVCodecParameters *parameters =
        context->format->streams[packet->stream_index]->codecpar;
    if (parameters->codec_type == AVMEDIA_TYPE_AUDIO &&
        parameters->codec_id == AV_CODEC_ID_AAC) {
      ylf_prime_aac_from_adts(parameters, packet->data, (size_t)packet->size);
    } else if (parameters->codec_type == AVMEDIA_TYPE_VIDEO &&
               parameters->extradata_size == 0 &&
               (parameters->codec_id == AV_CODEC_ID_H264 ||
                parameters->codec_id == AV_CODEC_ID_HEVC)) {
      bool annex_b = packet->data[0] == 0 && packet->data[1] == 0 &&
                     (packet->data[2] == 1 ||
                      (packet->data[2] == 0 && packet->data[3] == 1));
      if (annex_b) {
        parameters->extradata = av_mallocz(
            (size_t)packet->size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (parameters->extradata == NULL) {
          av_packet_free(&packet);
          return YLFResultOpenFailed;
        }
        memcpy(parameters->extradata, packet->data, (size_t)packet->size);
        parameters->extradata_size = packet->size;
      }
    }
    needs_metadata = ylf_annexb_needs_metadata(context->format);
  }
  av_packet_free(&packet);
  if (!read_any) return ylf_callback_failure(context, YLFResultOpenFailed);
  return ylf_reset_after_annexb_probe(context);
}

static int32_t ylf_discover_streams(struct YLFMediaContext *context,
                                    YLFMediaInfo *out_info) {
  if (!ylf_is_supported_input_format(context->format->iformat)) {
    return YLFResultUnsupportedContainer;
  }
  if (avformat_find_stream_info(context->format, NULL) < 0) {
    return ylf_callback_failure(context, YLFResultOpenFailed);
  }
  int32_t prime_result = ylf_prime_annexb_video_config(context);
  if (prime_result != YLFResultOK) return prime_result;
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
  case AV_CODEC_ID_AC3:
    return YLFCodecAC3;
  case AV_CODEC_ID_EAC3:
    return YLFCodecEAC3;
  case AV_CODEC_ID_FLAC:
    return YLFCodecFLAC;
  case AV_CODEC_ID_OPUS:
    return YLFCodecOpus;
  case AV_CODEC_ID_VORBIS:
    return YLFCodecVorbis;
  case AV_CODEC_ID_VP9:
    return YLFCodecVP9;
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

static bool ylf_start_code_at(const uint8_t *data,
                              size_t size,
                              size_t offset,
                              size_t *out_length) {
  if (offset + 3 <= size && data[offset] == 0 && data[offset + 1] == 0 &&
      data[offset + 2] == 1) {
    *out_length = 3;
    return true;
  }
  if (offset + 4 <= size && data[offset] == 0 && data[offset + 1] == 0 &&
      data[offset + 2] == 0 && data[offset + 3] == 1) {
    *out_length = 4;
    return true;
  }
  return false;
}

static bool ylf_find_start_code(const uint8_t *data,
                                size_t size,
                                size_t search_offset,
                                size_t *out_offset,
                                size_t *out_length) {
  for (size_t offset = search_offset; offset + 3 <= size; offset++) {
    if (ylf_start_code_at(data, size, offset, out_length)) {
      *out_offset = offset;
      return true;
    }
  }
  return false;
}

static OSStatus ylf_annexb_format_description(
    enum AVCodecID codec,
    const uint8_t *data,
    size_t size,
    CMVideoFormatDescriptionRef *out_description) {
  const uint8_t *parameter_sets[16];
  size_t parameter_set_sizes[16];
  size_t parameter_set_count = 0;
  bool saw_vps = codec != AV_CODEC_ID_HEVC;
  bool saw_sps = false;
  bool saw_pps = false;
  size_t start = 0;
  size_t prefix = 0;
  if (!ylf_find_start_code(data, size, 0, &start, &prefix)) {
    return kCMFormatDescriptionError_InvalidParameter;
  }
  while (start < size) {
    size_t nal_start = start + prefix;
    size_t next = size;
    size_t next_prefix = 0;
    bool has_next = ylf_find_start_code(data, size, nal_start, &next,
                                        &next_prefix);
    size_t nal_end = next;
    while (nal_end > nal_start && data[nal_end - 1] == 0) {
      nal_end--;
    }
    if (nal_end > nal_start) {
      uint8_t nal_type = codec == AV_CODEC_ID_HEVC
                             ? (data[nal_start] >> 1) & 0x3f
                             : data[nal_start] & 0x1f;
      bool wanted = codec == AV_CODEC_ID_HEVC
                        ? (nal_type == 32 || nal_type == 33 || nal_type == 34)
                        : (nal_type == 7 || nal_type == 8);
      if (wanted && parameter_set_count < 16) {
        parameter_sets[parameter_set_count] = data + nal_start;
        parameter_set_sizes[parameter_set_count++] = nal_end - nal_start;
        saw_vps |= nal_type == 32;
        saw_sps |= codec == AV_CODEC_ID_HEVC ? nal_type == 33 : nal_type == 7;
        saw_pps |= codec == AV_CODEC_ID_HEVC ? nal_type == 34 : nal_type == 8;
      }
    }
    if (!has_next) break;
    start = next;
    prefix = next_prefix;
  }
  if (!saw_vps || !saw_sps || !saw_pps) {
    return kCMFormatDescriptionError_InvalidParameter;
  }
  if (codec == AV_CODEC_ID_HEVC) {
    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        kCFAllocatorDefault, parameter_set_count, parameter_sets,
        parameter_set_sizes, 4, NULL, out_description);
  }
  return CMVideoFormatDescriptionCreateFromH264ParameterSets(
      kCFAllocatorDefault, parameter_set_count, parameter_sets,
      parameter_set_sizes, 4, out_description);
}

static bool ylf_convert_annexb_packet(AVPacket **packet_pointer) {
  AVPacket *packet = *packet_pointer;
  size_t first = 0;
  size_t first_prefix = 0;
  if (packet == NULL || packet->data == NULL || packet->size <= 0 ||
      !ylf_find_start_code(packet->data, (size_t)packet->size, 0, &first,
                           &first_prefix) || first != 0) {
    return true;
  }

  size_t output_size = 0;
  size_t start = first;
  size_t prefix = first_prefix;
  size_t nal_count = 0;
  while (start < (size_t)packet->size) {
    size_t nal_start = start + prefix;
    size_t next = (size_t)packet->size;
    size_t next_prefix = 0;
    bool has_next = ylf_find_start_code(packet->data, (size_t)packet->size,
                                        nal_start, &next, &next_prefix);
    size_t nal_end = next;
    while (nal_end > nal_start && packet->data[nal_end - 1] == 0) nal_end--;
    if (nal_end > nal_start) {
      size_t nal_size = nal_end - nal_start;
      if (nal_size > UINT32_MAX || nal_size > INT_MAX - 4 ||
          output_size > (size_t)INT_MAX - 4 - nal_size) {
        return false;
      }
      output_size += 4 + nal_size;
      nal_count++;
    }
    if (!has_next) break;
    start = next;
    prefix = next_prefix;
  }
  if (nal_count == 0 || output_size == 0) return false;

  AVPacket *converted = av_packet_alloc();
  if (converted == NULL || av_new_packet(converted, (int)output_size) < 0 ||
      av_packet_copy_props(converted, packet) < 0) {
    av_packet_free(&converted);
    return false;
  }
  converted->stream_index = packet->stream_index;
  size_t output_offset = 0;
  start = first;
  prefix = first_prefix;
  while (start < (size_t)packet->size) {
    size_t nal_start = start + prefix;
    size_t next = (size_t)packet->size;
    size_t next_prefix = 0;
    bool has_next = ylf_find_start_code(packet->data, (size_t)packet->size,
                                        nal_start, &next, &next_prefix);
    size_t nal_end = next;
    while (nal_end > nal_start && packet->data[nal_end - 1] == 0) nal_end--;
    if (nal_end > nal_start) {
      uint32_t nal_size = (uint32_t)(nal_end - nal_start);
      converted->data[output_offset++] = (uint8_t)(nal_size >> 24);
      converted->data[output_offset++] = (uint8_t)(nal_size >> 16);
      converted->data[output_offset++] = (uint8_t)(nal_size >> 8);
      converted->data[output_offset++] = (uint8_t)nal_size;
      memcpy(converted->data + output_offset, packet->data + nal_start,
             nal_size);
      output_offset += nal_size;
    }
    if (!has_next) break;
    start = next;
    prefix = next_prefix;
  }
  av_packet_free(packet_pointer);
  *packet_pointer = converted;
  return true;
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
  return ylf_open_callbacks_with_time_seek(opaque,
                                           read_callback,
                                           seek_callback,
                                           NULL,
                                           cancel_callback,
                                           out_context,
                                           out_info);
}

int32_t ylf_open_callbacks_with_time_seek(
    void *opaque,
    YLFReadCallback read_callback,
    YLFSeekCallback seek_callback,
    YLFTimeSeekCallback time_seek_callback,
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
  context->time_seek_callback = time_seek_callback;
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
  if (parameters->ch_layout.order == AV_CHANNEL_ORDER_NATIVE)
    out_info->channel_layout_mask = parameters->ch_layout.u.mask;
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

static bool ylf_strip_single_adts_header(AVPacket *packet) {
  if (packet == NULL || packet->data == NULL || packet->size < 7 ||
      packet->data[0] != 0xff || (packet->data[1] & 0xf6) != 0xf0) {
    return true;
  }
  int header_size = (packet->data[1] & 0x01) != 0 ? 7 : 9;
  int frame_size = ((packet->data[3] & 0x03) << 11) |
                   (packet->data[4] << 3) |
                   (packet->data[5] >> 5);
  if (header_size >= frame_size || frame_size != packet->size ||
      av_packet_make_writable(packet) < 0) {
    return false;
  }
  memmove(packet->data, packet->data + header_size,
          (size_t)(packet->size - header_size));
  packet->size -= header_size;
  return true;
}

// AVI often stores decode timestamps only. Only Baseline AVC (no B pictures)
// with zero declared reorder delay can use DTS as its missing presentation time.
// Never invent timestamps for Main/High, HEVC or unknown/reordered streams.
static bool ylf_normalize_avi_timing(AVFormatContext *format, AVPacket *packet) {
  if (!format->iformat || strcmp(format->iformat->name, "avi") != 0) return true;
  AVCodecParameters *parameters = format->streams[packet->stream_index]->codecpar;
  if (parameters->codec_type != AVMEDIA_TYPE_VIDEO || packet->pts != AV_NOPTS_VALUE) return true;
  if (parameters->codec_id != AV_CODEC_ID_H264 || parameters->video_delay != 0 ||
      (parameters->profile != AV_PROFILE_H264_BASELINE &&
       parameters->profile != AV_PROFILE_H264_CONSTRAINED_BASELINE) ||
      packet->dts == AV_NOPTS_VALUE) return false;
  packet->pts = packet->dts;
  return true;
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
  if (!ylf_normalize_avi_timing(context->format, packet->value)) {
    av_packet_free(&packet->value);
    free(packet);
    pthread_mutex_unlock(&context->mutex);
    return YLFResultVideoConfigurationInvalid;
  }
  AVCodecParameters *parameters =
      context->format->streams[packet->value->stream_index]->codecpar;
  bool is_mpegts = context->format->iformat != NULL &&
                   strstr(context->format->iformat->name, "mpegts") != NULL;
  if (is_mpegts && parameters->codec_id == AV_CODEC_ID_AAC &&
      !ylf_strip_single_adts_header(packet->value)) {
    av_packet_free(&packet->value);
    free(packet);
    pthread_mutex_unlock(&context->mutex);
    return YLFResultReadFailed;
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

int32_t ylf_use_relative_transport_stream_timestamps(YLFMediaContextRef context) {
  if (context == NULL) return YLFResultInvalidArgument;
  pthread_mutex_lock(&context->mutex);
  // Opt in only before consuming packets on standalone TS. HLS owns its own
  // time-seek callback and must retain the existing timestamp behavior.
  bool valid = context->format != NULL && context->format->iformat != NULL &&
      strcmp(context->format->iformat->name, "mpegts") == 0 &&
      context->format->start_time != AV_NOPTS_VALUE &&
      context->time_seek_callback == NULL && context->packets == NULL;
  if (valid) {
    context->timeline_origin_us = context->format->start_time;
    context->relative_transport_stream_timeline = true;
  }
  pthread_mutex_unlock(&context->mutex);
  return valid ? YLFResultOK : YLFResultUnsupportedContainer;
}

// MPEG-TS timestamp seeks and AVI synthesized indexes may land away from an
// IDR. Find a decodable anchor at/before the requested video time, then replay
// from that seek point through the existing keyframe gate and output suppression.
// These are search-work guards, not software-decoder performance allowances.
static int ylf_seek_video_anchor(struct YLFMediaContext *context,
                                           int64_t position_us, int64_t absolute_us) {
  int video = -1;
  for (unsigned int i = 0; i < context->format->nb_streams; i++) {
    enum AVCodecID codec = context->format->streams[i]->codecpar->codec_id;
    if (context->format->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO &&
        (codec == AV_CODEC_ID_H264 || codec == AV_CODEC_ID_HEVC)) { video = (int)i; break; }
  }
  if (video < 0) return AVERROR_INVALIDDATA;
  AVStream *stream = context->format->streams[video];
  int64_t first_us = ylf_timestamp_us(stream->start_time, stream->time_base);
  int64_t latest_anchor_us = FFMAX(absolute_us, first_us);
  AVPacket *packet = av_packet_alloc();
  if (packet == NULL) return AVERROR(ENOMEM);
  int result = AVERROR_INVALIDDATA;
  for (int64_t window = 1000000; window <= 8000000; window *= 2) {
    int64_t probe_us = FFMAX((int64_t)0, position_us - window), absolute_probe;
    if (__builtin_add_overflow(probe_us, context->timeline_origin_us, &absolute_probe)) break;
    result = avformat_seek_file(context->format, -1, INT64_MIN, absolute_probe, absolute_probe, 0);
    if (result < 0) break;
    avformat_flush(context->format);
    int64_t scanned_bytes = 0;
    bool found = false;
    for (int count = 0; count < 512 && scanned_bytes < 8 * 1024 * 1024; count++) {
      av_packet_unref(packet);
      result = av_read_frame(context->format, packet);
      if (result < 0) break;
      scanned_bytes += FFMAX(packet->size, 0);
      if (scanned_bytes > 8 * 1024 * 1024) break;
      if (packet->stream_index != video || !(packet->flags & AV_PKT_FLAG_KEY)) continue;
      if (!ylf_normalize_avi_timing(context->format, packet)) break;
      int64_t pts = ylf_timestamp_us(packet->pts, stream->time_base);
      if (pts == INT64_MIN) continue;
      found = pts <= latest_anchor_us;
      break;
    }
    av_packet_unref(packet);
    if (found) {
      result = avformat_seek_file(context->format, -1, INT64_MIN, absolute_probe, absolute_probe, 0);
      break;
    }
    result = AVERROR_INVALIDDATA;
    if (probe_us == 0 || atomic_load_explicit(&context->cancelled, memory_order_relaxed) ||
        context->callback_result != 0) break;
  }
  av_packet_free(&packet);
  return result;
}

int32_t ylf_seek(YLFMediaContextRef context, int64_t position_us) {
  if (context == NULL || position_us < 0) {
    return YLFResultInvalidArgument;
  }
  pthread_mutex_lock(&context->mutex);
  if (context->time_seek_callback != NULL) {
    context->callback_result = 0;
    int64_t actual_position = context->time_seek_callback(
        context->callback_opaque,
        position_us);
    if (actual_position >= 0) {
      if (context->avio != NULL) {
        context->avio->buf_ptr = context->avio->buf_end;
        context->avio->eof_reached = 0;
        context->avio->error = 0;
        context->avio->pos = 0;
      }
      avformat_flush(context->format);
      pthread_mutex_unlock(&context->mutex);
      return YLFResultOK;
    }
    context->callback_result = (int32_t)actual_position;
    pthread_mutex_unlock(&context->mutex);
    return ylf_callback_failure(context, YLFResultSeekFailed);
  }
  // Decode at least 80 ms for Opus; Vorbis needs two overlap blocks (200 ms).
  // Keep this local to the demux cursor; the player retains its original target.
  int preroll_us = 0;
  for (unsigned i = 0; i < context->format->nb_streams; i++) {
    if (context->format->streams[i]->codecpar->codec_id == AV_CODEC_ID_OPUS) preroll_us = FFMAX(preroll_us, 80000);
    preroll_us = FFMAX(preroll_us, ylf_stream_vorbis_preroll_us(context, (int32_t)i));
  }
  if (preroll_us) position_us = FFMAX(0, position_us - preroll_us);
  int64_t absolute_position_us;
  if (__builtin_add_overflow(position_us, context->timeline_origin_us, &absolute_position_us) ||
      absolute_position_us == AV_NOPTS_VALUE) {
    pthread_mutex_unlock(&context->mutex);
    return YLFResultSeekFailed;
  }
  if (preroll_us && position_us == 0) {
    // A video cue at zero can suppress the first negative-PTS Opus packet.
    // Anchor at the earliest delayed audio packet so Matroska retains it and
    // the following initial video keyframe. Positive-start tracks use video.
    int audio_index = -1; int64_t earliest_us = 0, audio_start = 0;
    for (unsigned i = 0; i < context->format->nb_streams; i++) {
      bool vorbis = ylf_stream_vorbis_preroll_us(context, (int32_t)i) > 0;
      int delay = vorbis ? 0 : ylf_stream_opus_delay_samples(context, (int32_t)i);
      AVStream *st = context->format->streams[i];
      int64_t first;
      if (delay < 0 || __builtin_sub_overflow(st->start_time,
          av_rescale_q(delay, (AVRational){1,48000}, st->time_base), &first)) continue;
      int64_t first_us = ylf_timestamp_us(first, st->time_base);
      if (first_us < earliest_us) { earliest_us = first_us; audio_index = i; audio_start = first; }
    }
    if (audio_index >= 0) {
      int result = avformat_seek_file(context->format, audio_index, INT64_MIN,
          audio_start, audio_start, AVSEEK_FLAG_BACKWARD);
      if (result >= 0) avformat_flush(context->format);
      pthread_mutex_unlock(&context->mutex);
      return result >= 0 ? YLFResultOK : ylf_callback_failure(context, YLFResultSeekFailed);
    }
  }
  bool is_avi = context->format->iformat && strcmp(context->format->iformat->name, "avi") == 0;
  int result = (context->relative_transport_stream_timeline || is_avi)
      ? ylf_seek_video_anchor(context, position_us, absolute_position_us)
      : avformat_seek_file(context->format,
                                  -1,
                                  INT64_MIN,
                                  absolute_position_us,
                                  preroll_us ? absolute_position_us : INT64_MAX,
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

static int64_t ylf_relative_timestamp_us(YLFPacketRef packet, int64_t timestamp) {
  AVStream *stream = packet->owner->format->streams[packet->value->stream_index];
  int64_t raw = ylf_timestamp_us(timestamp, stream->time_base), relative;
  if (raw == INT64_MIN || __builtin_sub_overflow(raw, packet->owner->timeline_origin_us, &relative)) {
    return INT64_MIN;
  }
  return relative;
}

int64_t ylf_packet_pts_us(YLFPacketRef packet) {
  if (packet == NULL || packet->value == NULL || packet->owner == NULL) {
    return INT64_MIN;
  }
  return ylf_relative_timestamp_us(packet, packet->value->pts);
}

int64_t ylf_packet_dts_us(YLFPacketRef packet) {
  if (packet == NULL || packet->value == NULL || packet->owner == NULL) {
    return INT64_MIN;
  }
  return ylf_relative_timestamp_us(packet, packet->value->dts);
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

static const AVPacketSideData *ylf_video_side_data(
    const AVCodecParameters *parameters, enum AVPacketSideDataType type) {
  return av_packet_side_data_get(parameters->coded_side_data,
                                 parameters->nb_coded_side_data, type);
}

static CFStringRef ylf_color_primaries(enum AVColorPrimaries value) {
  switch (value) {
  case AVCOL_PRI_BT709: return kCMFormatDescriptionColorPrimaries_ITU_R_709_2;
  case AVCOL_PRI_BT470BG: return kCMFormatDescriptionColorPrimaries_EBU_3213;
  case AVCOL_PRI_SMPTE170M:
  case AVCOL_PRI_SMPTE240M: return kCMFormatDescriptionColorPrimaries_SMPTE_C;
  case AVCOL_PRI_BT2020: return kCMFormatDescriptionColorPrimaries_ITU_R_2020;
  case AVCOL_PRI_SMPTE431: return kCMFormatDescriptionColorPrimaries_DCI_P3;
  case AVCOL_PRI_SMPTE432: return kCMFormatDescriptionColorPrimaries_P3_D65;
  default: return NULL;
  }
}

static CFStringRef ylf_transfer_function(enum AVColorTransferCharacteristic value) {
  switch (value) {
  case AVCOL_TRC_BT709:
  case AVCOL_TRC_SMPTE170M:
  case AVCOL_TRC_BT2020_10:
  case AVCOL_TRC_BT2020_12: return kCMFormatDescriptionTransferFunction_ITU_R_709_2;
  case AVCOL_TRC_SMPTE240M: return kCMFormatDescriptionTransferFunction_SMPTE_240M_1995;
  case AVCOL_TRC_LINEAR: return kCMFormatDescriptionTransferFunction_Linear;
  case AVCOL_TRC_IEC61966_2_1: return kCMFormatDescriptionTransferFunction_sRGB;
  case AVCOL_TRC_SMPTE2084: return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ;
  case AVCOL_TRC_ARIB_STD_B67: return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG;
  case AVCOL_TRC_SMPTE428: return kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1;
  default: return NULL;
  }
}

static CFStringRef ylf_color_matrix(enum AVColorSpace value) {
  switch (value) {
  case AVCOL_SPC_BT709: return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2;
  case AVCOL_SPC_BT470BG:
  case AVCOL_SPC_SMPTE170M: return kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4;
  case AVCOL_SPC_SMPTE240M: return kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995;
  case AVCOL_SPC_BT2020_NCL: return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020;
  default: return NULL;
  }
}

static void ylf_set_color(NSMutableDictionary *extensions, CFStringRef key,
                           CFStringRef value) {
  if (value) extensions[(__bridge NSString *)key] = (__bridge NSString *)value;
  else [extensions removeObjectForKey:(__bridge NSString *)key];
}

static void ylf_write_be16(uint8_t *bytes, uint32_t value) {
  bytes[0] = (uint8_t)(value >> 8); bytes[1] = (uint8_t)value;
}

static void ylf_write_be32(uint8_t *bytes, uint32_t value) {
  ylf_write_be16(bytes, value >> 16); ylf_write_be16(bytes + 2, value);
}

static bool ylf_hdr_value(AVRational value, uint32_t scale, uint32_t maximum,
                           uint32_t *result) {
  if (value.den <= 0 || value.num < 0) return false;
  int64_t scaled = av_rescale(value.num, scale, value.den);
  if (scaled < 0 || scaled > maximum) return false;
  *result = (uint32_t)scaled;
  return true;
}

static bool ylf_apply_static_hdr(const AVCodecParameters *parameters,
                                  NSMutableDictionary *extensions,
                                  NSMutableDictionary *atoms) {
  const AVPacketSideData *side = ylf_video_side_data(parameters, AV_PKT_DATA_MASTERING_DISPLAY_METADATA);
  if (side) {
    if (!side->data || side->size < sizeof(AVMasteringDisplayMetadata)) return false;
    AVMasteringDisplayMetadata metadata;
    memcpy(&metadata, side->data, sizeof(metadata));
    if (metadata.has_primaries && metadata.has_luminance) {
      uint8_t bytes[24] = {0};
      // FFmpeg stores R,G,B; HEVC mastering-display SEI stores G,B,R.
      const int order[3] = {1, 2, 0};
      uint32_t value, minimum, maximum;
      for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 2; j++) {
          if (!ylf_hdr_value(metadata.display_primaries[order[i]][j], 50000, 50000, &value)) return false;
          ylf_write_be16(bytes + i * 4 + j * 2, value);
        }
      }
      for (int j = 0; j < 2; j++) {
        if (!ylf_hdr_value(metadata.white_point[j], 50000, 50000, &value)) return false;
        ylf_write_be16(bytes + 12 + j * 2, value);
      }
      if (!ylf_hdr_value(metadata.max_luminance, 10000, UINT32_MAX, &maximum) ||
          !ylf_hdr_value(metadata.min_luminance, 10000, UINT32_MAX, &minimum) ||
          maximum == 0 || minimum > maximum) return false;
      ylf_write_be32(bytes + 16, maximum);
      ylf_write_be32(bytes + 20, minimum);
      NSData *data = [NSData dataWithBytes:bytes length:sizeof(bytes)];
      extensions[(__bridge NSString *)kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = data;
      atoms[@"mdcv"] = data;
    }
  }
  side = ylf_video_side_data(parameters, AV_PKT_DATA_CONTENT_LIGHT_LEVEL);
  if (side) {
    if (!side->data || side->size < sizeof(AVContentLightMetadata)) return false;
    AVContentLightMetadata metadata;
    memcpy(&metadata, side->data, sizeof(metadata));
    if (metadata.MaxCLL > UINT16_MAX || metadata.MaxFALL > UINT16_MAX) return false;
    uint8_t bytes[4];
    ylf_write_be16(bytes, metadata.MaxCLL); ylf_write_be16(bytes + 2, metadata.MaxFALL);
    NSData *data = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    extensions[(__bridge NSString *)kCMFormatDescriptionExtension_ContentLightLevelInfo] = data;
    atoms[@"clli"] = data;
  }
  return true;
}

static OSStatus ylf_apply_video_metadata(const AVCodecParameters *parameters,
                                           CMVideoFormatDescriptionRef base,
                                           CMVideoFormatDescriptionRef *out_description) {
  NSMutableDictionary *extensions = [(__bridge NSDictionary *)CMFormatDescriptionGetExtensions(base) mutableCopy];
  if (!extensions) extensions = [NSMutableDictionary dictionary];
  NSString *atomsKey = (__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms;
  NSMutableDictionary *atoms = [extensions[atomsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
  CMVideoCodecType codec = CMFormatDescriptionGetMediaSubType(base);
  const AVPacketSideData *side = ylf_video_side_data(parameters, AV_PKT_DATA_DOVI_CONF);
  if (side) {
    if (!side->data || side->size < sizeof(AVDOVIDecoderConfigurationRecord)) return kCMFormatDescriptionError_InvalidParameter;
    AVDOVIDecoderConfigurationRecord dovi;
    memcpy(&dovi, side->data, sizeof(dovi));
    // Classify common, structurally valid unsupported HEVC configurations
    // separately so callers do not attempt codec-configuration repair for them.
    bool validCommon = parameters->codec_id == AV_CODEC_ID_HEVC &&
        dovi.dv_version_major == 1 && dovi.dv_version_minor == 0 &&
        dovi.dv_level >= 1 && dovi.dv_level <= 13 &&
        dovi.rpu_present_flag == 1 && dovi.bl_present_flag == 1 &&
        dovi.dv_md_compression == AV_DOVI_COMPRESSION_NONE;
    bool profile7 = dovi.dv_profile == 7 && dovi.el_present_flag == 1 &&
        dovi.dv_bl_signal_compatibility_id == 6;
    bool profile8 = dovi.dv_profile == 8 && dovi.el_present_flag == 0 &&
        (dovi.dv_bl_signal_compatibility_id == 1 ||
         dovi.dv_bl_signal_compatibility_id == 2 ||
         dovi.dv_bl_signal_compatibility_id == 4);
    if (validCommon && (profile7 || profile8)) return YLFResultDolbyVisionUnsupported;
    // Only the single-layer, uncompressed Profile 5 path is qualified. Never
    // silently decode unsupported DV as ordinary HEVC (its BL may not be HDR10).
    if (parameters->codec_id != AV_CODEC_ID_HEVC || dovi.dv_version_major != 1 ||
        dovi.dv_version_minor != 0 || dovi.dv_profile != 5 ||
        dovi.dv_level < 1 || dovi.dv_level > 9 ||
        dovi.rpu_present_flag != 1 || dovi.el_present_flag != 0 ||
        dovi.bl_present_flag != 1 || dovi.dv_bl_signal_compatibility_id != 0 ||
        dovi.dv_md_compression != AV_DOVI_COMPRESSION_NONE) return kCMFormatDescriptionError_InvalidParameter;
    NSData *hvcc = atoms[@"hvcC"];
    const uint8_t *bytes = hvcc.bytes;
    if (hvcc.length < 23 || (bytes[16] & 3) != 1 ||
        (bytes[17] & 7) != 2 || (bytes[18] & 7) != 2) return kCMFormatDescriptionError_InvalidParameter;
    uint8_t dvcc[24] = {0};
    dvcc[0] = dovi.dv_version_major; dvcc[1] = dovi.dv_version_minor;
    dvcc[2] = (uint8_t)((dovi.dv_profile << 1) | (dovi.dv_level >> 5));
    dvcc[3] = (uint8_t)((dovi.dv_level << 3) | 5); // RPU + BL, no EL.
    atoms[@"dvcC"] = [NSData dataWithBytes:dvcc length:sizeof(dvcc)];
    codec = kCMVideoCodecType_DolbyVisionHEVC;
    // Profile 5 is full-range IPT-PQ, with unspecified CICP values. Ordinary
    // YCbCr/PQ declarations on this BL would make its colours misleading.
    const uint8_t colr[] = {'n', 'c', 'l', 'c', 0, 2, 0, 2, 0, 2};
    atoms[@"colr"] = [NSData dataWithBytes:colr length:sizeof(colr)];
    ylf_set_color(extensions, kCMFormatDescriptionExtension_ColorPrimaries, NULL);
    ylf_set_color(extensions, kCMFormatDescriptionExtension_TransferFunction, NULL);
    ylf_set_color(extensions, kCMFormatDescriptionExtension_YCbCrMatrix, NULL);
    extensions[(__bridge NSString *)kCMFormatDescriptionExtension_FullRangeVideo] = @YES;
  } else {
    if (parameters->color_primaries != AVCOL_PRI_UNSPECIFIED)
      ylf_set_color(extensions, kCMFormatDescriptionExtension_ColorPrimaries, ylf_color_primaries(parameters->color_primaries));
    if (parameters->color_trc != AVCOL_TRC_UNSPECIFIED)
      ylf_set_color(extensions, kCMFormatDescriptionExtension_TransferFunction, ylf_transfer_function(parameters->color_trc));
    if (parameters->color_space != AVCOL_SPC_UNSPECIFIED)
      ylf_set_color(extensions, kCMFormatDescriptionExtension_YCbCrMatrix, ylf_color_matrix(parameters->color_space));
    if (parameters->color_range == AVCOL_RANGE_JPEG || parameters->color_range == AVCOL_RANGE_MPEG)
      extensions[(__bridge NSString *)kCMFormatDescriptionExtension_FullRangeVideo] = @(parameters->color_range == AVCOL_RANGE_JPEG);
    // Keep the original colr values for fields the container did not declare.
    NSData *oldColr = atoms[@"colr"];
    uint8_t colr[] = {'n', 'c', 'l', 'c', 0, 2, 0, 2, 0, 2};
    if (oldColr.length >= 10 && (!memcmp(oldColr.bytes, "nclc", 4) || !memcmp(oldColr.bytes, "nclx", 4)))
      memcpy(colr + 4, (const uint8_t *)oldColr.bytes + 4, 6);
    const int values[] = {parameters->color_primaries, parameters->color_trc, parameters->color_space};
    for (int i = 0; i < 3; i++) {
      if (values[i] != 2 && values[i] >= 0 && values[i] <= UINT16_MAX)
        ylf_write_be16(colr + 4 + i * 2, (uint32_t)values[i]);
    }
    atoms[@"colr"] = [NSData dataWithBytes:colr length:sizeof(colr)];
    if (!ylf_apply_static_hdr(parameters, extensions, atoms)) return kCMFormatDescriptionError_InvalidParameter;
  }
  extensions[atomsKey] = atoms;
  CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(base);
  return CMVideoFormatDescriptionCreate(kCFAllocatorDefault, codec,
      dimensions.width, dimensions.height, (__bridge CFDictionaryRef)extensions, out_description);
}

int32_t ylf_copy_video_format_description_with_codec_config(
    YLFMediaContextRef context, int32_t stream_index,
    const uint8_t *configuration, size_t configuration_size,
    CMVideoFormatDescriptionRef *out_description) {
  if (out_description == NULL) return YLFResultVideoConfigurationInvalid;
  *out_description = NULL;
  if (context == NULL || context->format == NULL || stream_index < 0 ||
      (unsigned int)stream_index >= context->format->nb_streams ||
      configuration == NULL || configuration_size == 0) return YLFResultVideoConfigurationInvalid;
  const AVCodecParameters *parameters = context->format->streams[stream_index]->codecpar;
  if (parameters->codec_type == AVMEDIA_TYPE_VIDEO && parameters->codec_id == AV_CODEC_ID_VP9) {
    // VP Codec Configuration Box v1, supplied by the bounded keyframe probe.
    // This initial route does not downgrade HDR, chroma or bit depth.
    if (configuration_size != 12 || configuration[0] != 1 || configuration[1] ||
        configuration[2] || configuration[3] || configuration[4] != 0 ||
        configuration[5] != 0 || (configuration[6] & 0xfe) != 0x82 ||
        configuration[10] || configuration[11] || parameters->width <= 0 ||
        parameters->height <= 0 || parameters->width > 4096 || parameters->height > 2160 ||
        ylf_video_side_data(parameters, AV_PKT_DATA_DOVI_CONF) ||
        ylf_video_side_data(parameters, AV_PKT_DATA_MASTERING_DISPLAY_METADATA) ||
        ylf_video_side_data(parameters, AV_PKT_DATA_CONTENT_LIGHT_LEVEL)) return YLFResultVideoConfigurationInvalid;
    const int colors[] = {configuration[7], configuration[8], configuration[9],
      parameters->color_primaries, parameters->color_trc, parameters->color_space};
    for (int i = 0; i < 6; i++)
      if (colors[i] != 1 && colors[i] != 2 && colors[i] != 6) return YLFResultVideoConfigurationInvalid;
    uint8_t vpc[12]; memcpy(vpc, configuration, 12);
    for (int i = 0; i < 3; i++) {
      if (colors[i] != 2 && colors[i+3] != 2 && colors[i] != colors[i+3]) return YLFResultVideoConfigurationInvalid;
      if (colors[i+3] != 2) vpc[7+i] = colors[i+3];
    }
    if (parameters->color_range != AVCOL_RANGE_UNSPECIFIED &&
        ((parameters->color_range == AVCOL_RANGE_JPEG) != ((vpc[6] & 1) != 0))) return YLFResultVideoConfigurationInvalid;
    NSData *record = [NSData dataWithBytes:vpc length:12];
    NSDictionary *ext = @{(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: @{ @"vpcC": record },
      (__bridge NSString *)kCMFormatDescriptionExtension_FullRangeVideo: @((vpc[6] & 1) != 0)};
    CMVideoFormatDescriptionRef base = NULL;
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_VP9,
      parameters->width, parameters->height, (__bridge CFDictionaryRef)ext, &base);
    if (status == noErr && base) status = ylf_apply_video_metadata(parameters, base, out_description);
    if (base) CFRelease(base);
    return status == noErr && *out_description ? YLFResultOK : YLFResultVideoConfigurationInvalid;
  }
  if (parameters->codec_type != AVMEDIA_TYPE_VIDEO ||
      (parameters->codec_id != AV_CODEC_ID_H264 && parameters->codec_id != AV_CODEC_ID_HEVC)) return YLFResultVideoConfigurationInvalid;
  CMVideoFormatDescriptionRef base = NULL;
  OSStatus status = configuration[0] != 1
      ? ylf_annexb_format_description(parameters->codec_id, configuration, configuration_size, &base)
      : parameters->codec_id == AV_CODEC_ID_H264
          ? ylf_h264_format_description(configuration, configuration_size, &base)
          : ylf_hevc_format_description(configuration, configuration_size, &base);
  if (status == noErr && base != NULL)
    status = ylf_apply_video_metadata(parameters, base, out_description);
  if (base) CFRelease(base);
  if (status == YLFResultDolbyVisionUnsupported) return YLFResultDolbyVisionUnsupported;
  return status == noErr && *out_description != NULL ? YLFResultOK : YLFResultVideoConfigurationInvalid;
}

int32_t ylf_copy_video_format_description(
    YLFMediaContextRef context, int32_t stream_index,
    CMVideoFormatDescriptionRef *out_description) {
  if (out_description == NULL) return YLFResultVideoConfigurationInvalid;
  *out_description = NULL;
  if (context == NULL || context->format == NULL || stream_index < 0 ||
      (unsigned int)stream_index >= context->format->nb_streams) return YLFResultVideoConfigurationInvalid;
  const AVCodecParameters *parameters = context->format->streams[stream_index]->codecpar;
  return ylf_copy_video_format_description_with_codec_config(context, stream_index,
      parameters->extradata, parameters->extradata_size > 0 ? (size_t)parameters->extradata_size : 0, out_description);
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
  const AVCodecParameters *parameters = stream->codecpar;
  bool nal_codec = parameters->codec_id == AV_CODEC_ID_H264 ||
                   parameters->codec_id == AV_CODEC_ID_HEVC;
  // The demuxed stream's avcC/hvcC record declares length-prefixed packets.
  // A valid four-byte NAL length 0x000001xx looks like a three-byte Annex B
  // start code. Never sniff/convert those packets based on their payload.
  // Use demux framing, not the output CM format (Annex B is also normalized
  // to avcC/hvcC there). Preserve the existing recovery for missing config.
  bool length_prefixed = nal_codec && parameters->extradata != NULL &&
      parameters->extradata_size > 0 && parameters->extradata[0] == 1;
  if (nal_codec && !length_prefixed &&
      !ylf_convert_annexb_packet(&packet->value)) {
    return YLFResultSampleBufferFailed;
  }
  bool is_keyframe = (packet->value->flags & AV_PKT_FLAG_KEY) != 0;
  CMSampleTimingInfo timing = {
      .duration = packet->value->duration > 0
                      ? CMTimeMake(ylf_timestamp_us(packet->value->duration,
                                                    stream->time_base),
                                   AV_TIME_BASE)
                      : kCMTimeInvalid,
      .presentationTimeStamp = ylf_packet_pts_us(packet) == INT64_MIN
          ? kCMTimeInvalid : CMTimeMake(ylf_packet_pts_us(packet), AV_TIME_BASE),
      .decodeTimeStamp = ylf_packet_dts_us(packet) == INT64_MIN
          ? kCMTimeInvalid : CMTimeMake(ylf_packet_dts_us(packet), AV_TIME_BASE),
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

#include "YlFELBridge.inc"

int32_t ylf_stream_opus_delay_samples(YLFMediaContextRef context, int32_t index) {
  if (!context || !context->format || index < 0 || (unsigned)index >= context->format->nb_streams ||
      !context->format->iformat || !strstr(context->format->iformat->name, "matroska")) return -1;
  AVStream *stream = context->format->streams[index];
  AVCodecParameters *p = stream->codecpar;
  if (p->codec_id != AV_CODEC_ID_OPUS || p->sample_rate != 48000 ||
      p->extradata_size != 19 || !p->extradata || memcmp(p->extradata, "OpusHead", 8) ||
      p->extradata[8] != 1 || p->extradata[18] != 0 || p->extradata[9] < 1 || p->extradata[9] > 2 ||
      p->ch_layout.nb_channels != p->extradata[9] || p->initial_padding != AV_RL16(p->extradata + 10) ||
      p->seek_preroll < 0 || p->seek_preroll > 3840 || stream->start_time == AV_NOPTS_VALUE) return -1;
  return p->initial_padding;
}

int32_t ylf_packet_audio_trim(YLFPacketRef packet, uint32_t *skip, uint32_t *discard) {
  if (!packet || !packet->value || !packet->owner || !skip || !discard) return YLFResultInvalidArgument;
  *skip = 0; *discard = 0;
  AVPacket *p = packet->value;
  bool vorbis = ylf_stream_vorbis_preroll_us(packet->owner, p->stream_index) > 0;
  int32_t delay = vorbis ? 0 : ylf_stream_opus_delay_samples(packet->owner, p->stream_index);
  if (delay < 0 || p->pts == AV_NOPTS_VALUE) return YLFResultAudioConfigurationUnsupported;
  size_t size = 0;
  const uint8_t *side = av_packet_get_side_data(p, AV_PKT_DATA_SKIP_SAMPLES, &size);
  if (side) {
    if (size != 10) return YLFResultReadFailed;
    *skip = AV_RL32(side); *discard = AV_RL32(side + 4);
    if (*skip > (vorbis ? 4096 : 65535) || *discard > (vorbis ? 4096 : 5760)) return YLFResultReadFailed;
  }
  // Leading container trim is outside the accepted Vorbis timestamp profile.
  if (vorbis) return *skip ? YLFResultReadFailed : YLFResultOK;
  // libavformat clears pending skip on seek. The timestamp of the original
  // first packet identifies the only position where CodecDelay applies again.
  AVStream *stream = packet->owner->format->streams[p->stream_index];
  int64_t first;
  if (__builtin_sub_overflow(stream->start_time,
      av_rescale_q(delay, (AVRational){1,48000}, stream->time_base), &first)) return YLFResultReadFailed;
  if (!*skip && p->pts == first) *skip = delay;
  return YLFResultOK;
}

struct YLFOpusDecoder {
  OpusDecoder *decoder;
  uint32_t pending_skip;
  int channels;
  float decoded[5760 * 2];
};

YLFOpusDecoderRef ylf_opus_create(const uint8_t *head, size_t size) {
  if (!head || size != 19 || memcmp(head, "OpusHead", 8) || head[8] != 1 ||
      head[9] < 1 || head[9] > 2 || head[18] != 0) return NULL;
  struct YLFOpusDecoder *d = calloc(1, sizeof(*d));
  if (!d) return NULL;
  int error = OPUS_OK;
  d->channels = head[9];
  d->decoder = opus_decoder_create(48000, d->channels, &error);
  // libopus applies the header's signed Q8 dB gain; pre-skip remains explicitly
  // owned by container packet metadata, never implicitly applied a second time.
  if (!d->decoder || error != OPUS_OK ||
      opus_decoder_ctl(d->decoder, OPUS_SET_GAIN((int16_t)AV_RL16(head + 16))) != OPUS_OK) {
    ylf_opus_free(d); return NULL;
  }
  return d;
}

int32_t ylf_opus_decode(YLFOpusDecoderRef d, const uint8_t *data, size_t size,
    uint32_t skip, uint32_t discard, float *samples, int32_t capacity_frames,
    int32_t *out_frames, int32_t *out_offset_frames) {
  if (out_frames) *out_frames = 0;
  if (out_offset_frames) *out_offset_frames = 0;
  if (!d || !data || !size || size > 65536 || !samples || !out_frames ||
      !out_offset_frames || skip > 65535) return YLFResultInvalidArgument;
  // The reference implementation validates SILK, hybrid and CELT packet duration.
  // Bounds/trim errors must not consume decoder history.
  int expected_frames = opus_packet_get_nb_samples(data, (opus_int32)size, 48000);
  if (expected_frames <= 0 || expected_frames > 5760 || capacity_frames < expected_frames ||
      discard > (uint32_t)expected_frames) return YLFResultInvalidArgument;
  uint32_t pending_skip = skip ? skip : d->pending_skip;
  int start = (int)FFMIN(pending_skip, (uint32_t)expected_frames);
  if (discard > (uint32_t)(expected_frames - start)) return YLFResultInvalidArgument;
  int result = opus_decode_float(d->decoder, data, (opus_int32)size, d->decoded, 5760, 0);
  if (result != expected_frames) return YLFResultReadFailed;
  int frames = expected_frames - start - (int)discard;
  for (int i = 0; i < frames * d->channels; i++) {
    float value = d->decoded[start * d->channels + i];
    if (!isfinite(value)) return YLFResultReadFailed;
    samples[i] = value;
  }
  d->pending_skip = pending_skip - start;
  *out_frames = frames;
  *out_offset_frames = start;
  return YLFResultOK;
}

void ylf_opus_reset(YLFOpusDecoderRef d) {
  if (!d) return;
  opus_decoder_ctl(d->decoder, OPUS_RESET_STATE);
  d->pending_skip = 0;
}
void ylf_opus_free(YLFOpusDecoderRef d) {
  if (!d) return;
  opus_decoder_destroy(d->decoder); free(d);
}

#include "YlVorbisBridge.inc"
