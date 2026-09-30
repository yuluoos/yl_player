int32_t ylf_stream_vorbis_preroll_us(YLFMediaContextRef context, int32_t index) {
  if (!context || !context->format || index < 0 || (unsigned)index >= context->format->nb_streams ||
      !context->format->iformat || !strstr(context->format->iformat->name, "matroska")) return -1;
  AVStream *st = context->format->streams[index];
  AVCodecParameters *p = st->codecpar;
  if (p->codec_id != AV_CODEC_ID_VORBIS || (p->sample_rate != 44100 && p->sample_rate != 48000) ||
      p->ch_layout.nb_channels < 1 || p->ch_layout.nb_channels > 2 ||
      p->initial_padding != 0 || p->seek_preroll != 0 || st->start_time == AV_NOPTS_VALUE ||
      p->extradata_size < 3 || p->extradata_size > 65536) return -1;
  // Two maximum output blocks (2 * 4096 / 44100 s), rounded upward.
  return 200000;
}

// The ordinary Matroska route has a deliberately bounded channel/rate/header
// profile. Full setup validation remains with the pinned FFmpeg decoder.
struct YLFVorbisDecoder {
  AVCodecContext *codec;
  AVFrame *frame;
  AVPacket *packet;
  int channels;
  int sample_rate;
};

YLFVorbisDecoderRef ylf_vorbis_create(const uint8_t *head, size_t size,
    int32_t sample_rate, int32_t channels) {
  if (!head || size < 3 || size > 65536 || head[0] != 2 ||
      (sample_rate != 44100 && sample_rate != 48000) || channels < 1 || channels > 2) return NULL;
  size_t cursor = 1, lengths[3] = {0};
  for (int i = 0; i < 2; i++) {
    uint8_t lace;
    do {
      if (cursor >= size) return NULL;
      lace = head[cursor++]; lengths[i] += lace;
    } while (lace == 255);
  }
  if (lengths[0] != 30 || lengths[0] > size - cursor ||
      lengths[1] > size - cursor - lengths[0]) return NULL;
  lengths[2] = size - cursor - lengths[0] - lengths[1];
  const uint8_t *id = head + cursor;
  const uint8_t *comment = id + lengths[0], *setup = comment + lengths[1];
  if (id[0] != 1 || memcmp(id + 1, "vorbis", 6) || AV_RL32(id + 7) != 0 ||
      id[11] != channels || AV_RL32(id + 12) != sample_rate || id[29] != 1 ||
      (id[28] & 15) < 6 || (id[28] >> 4) > 13 || (id[28] & 15) > (id[28] >> 4) ||
      lengths[1] < 7 || comment[0] != 3 || memcmp(comment + 1, "vorbis", 6) ||
      lengths[2] < 8 || setup[0] != 5 || memcmp(setup + 1, "vorbis", 6)) return NULL;
  const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_VORBIS);
  if (!codec) return NULL;
  struct YLFVorbisDecoder *d = calloc(1, sizeof(*d));
  if (!d) return NULL;
  d->codec = avcodec_alloc_context3(codec);
  d->frame = av_frame_alloc(); d->packet = av_packet_alloc();
  d->channels = channels; d->sample_rate = sample_rate;
  if (!d->codec || !d->frame || !d->packet) { ylf_vorbis_free(d); return NULL; }
  d->codec->extradata = av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
  if (!d->codec->extradata) { ylf_vorbis_free(d); return NULL; }
  memcpy(d->codec->extradata, head, size); d->codec->extradata_size = (int)size;
  d->codec->thread_count = 1;
  // Retain FFmpeg's automatic first overlap block discard. Do not expose that
  // priming block or reapply it in Swift/container code.
  if (avcodec_open2(d->codec, codec, NULL) < 0 ||
      d->codec->sample_rate != sample_rate || d->codec->ch_layout.nb_channels != channels) {
    ylf_vorbis_free(d); return NULL;
  }
  return d;
}

int32_t ylf_vorbis_decode(YLFVorbisDecoderRef d, const uint8_t *data, size_t size,
    uint32_t skip, uint32_t discard, float *samples, int32_t capacity_frames, int32_t *out_frames) {
  if (out_frames) *out_frames = 0;
  if (!d || !data || !size || size > 65536 || !samples || !out_frames ||
      capacity_frames < 4096 || skip > 4096 || discard > 4096) return YLFResultInvalidArgument;
  // Header replacement inside an audio packet is outside the configured stream
  // contract; reject before FFmpeg can change its channel/rate/setup state.
  if (data[0] & 1) return YLFResultReadFailed;
  av_packet_unref(d->packet);
  if (av_new_packet(d->packet, (int)size) < 0) return YLFResultReadFailed;
  memcpy(d->packet->data, data, size);
  if (skip || discard) {
    uint8_t *side = av_packet_new_side_data(d->packet, AV_PKT_DATA_SKIP_SAMPLES, 10);
    if (!side) { av_packet_unref(d->packet); return YLFResultReadFailed; }
    AV_WL32(side, skip); AV_WL32(side + 4, discard); side[8] = side[9] = 0;
  }
  int result = avcodec_send_packet(d->codec, d->packet);
  av_packet_unref(d->packet);
  if (result < 0) return YLFResultReadFailed;
  av_frame_unref(d->frame);
  result = avcodec_receive_frame(d->codec, d->frame);
  if (result == AVERROR(EAGAIN)) return YLFResultOK;
  AVFrame *f = d->frame;
  if (result < 0 || f->nb_samples < 0 || f->nb_samples > 4096 ||
      f->sample_rate != d->sample_rate || f->ch_layout.nb_channels != d->channels ||
      f->format != AV_SAMPLE_FMT_FLTP) { av_frame_unref(f); return YLFResultReadFailed; }
  for (int i = 0; i < f->nb_samples; i++) {
    for (int c = 0; c < d->channels; c++) {
      float value = ((float *)f->extended_data[c])[i];
      if (!isfinite(value)) { av_frame_unref(f); return YLFResultReadFailed; }
      samples[i * d->channels + c] = value;
    }
  }
  *out_frames = f->nb_samples;
  av_frame_unref(f);
  return YLFResultOK;
}
void ylf_vorbis_reset(YLFVorbisDecoderRef d) { if (d) avcodec_flush_buffers(d->codec); }
void ylf_vorbis_free(YLFVorbisDecoderRef d) {
  if (!d) return;
  avcodec_free_context(&d->codec); av_frame_free(&d->frame); av_packet_free(&d->packet); free(d);
}
