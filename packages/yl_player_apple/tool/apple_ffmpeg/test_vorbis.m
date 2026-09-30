#import <Foundation/Foundation.h>
#include <math.h>
#include <vorbis/codec.h>
#include <libavutil/intreadwrite.h>
#ifdef YL_VORBIS_ARTIFACT
#include "YlFFmpegBridge.h"
#include <libavformat/avformat.h>
#else
#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
#endif
static int checks, failures;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c); } } while (0)
static void fixture(const char *path) {
  YLFVorbisDecoderRef decoder = NULL;
  for (int pass = 0; pass < 2; pass++) {
    AVFormatContext *format = NULL;
    CHECK(avformat_open_input(&format, path, NULL, NULL) == 0);
    if (!format) return;
    AVCodecParameters *par = format->streams[0]->codecpar;
    int channels = par->ch_layout.nb_channels, rate = par->sample_rate;
    CHECK(par->codec_id == AV_CODEC_ID_VORBIS);
    if (!decoder) decoder = ylf_vorbis_create(par->extradata, par->extradata_size, rate, channels);
    else ylf_vorbis_reset(decoder);
    CHECK(decoder != NULL);
    if (!decoder) { avformat_close_input(&format); return; }
    CHECK(ylf_vorbis_create(par->extradata, par->extradata_size, rate, 3) == NULL);
    CHECK(ylf_vorbis_create(par->extradata, par->extradata_size, 8000, channels) == NULL);
    CHECK(ylf_vorbis_create(par->extradata, par->extradata_size, rate, channels == 1 ? 2 : 1) == NULL);
    CHECK(ylf_vorbis_create(par->extradata, par->extradata_size - 64, rate, channels) == NULL);
    CHECK(ylf_vorbis_create(par->extradata, 65537, rate, channels) == NULL);
    CHECK(ylf_vorbis_create(NULL, 0, rate, channels) == NULL);
    uint8_t badHead[3] = {2,255,255};
    CHECK(ylf_vorbis_create(badHead, sizeof(badHead), rate, channels) == NULL);
    vorbis_info vi; vorbis_comment vc; vorbis_dsp_state vd; vorbis_block vb;
    vorbis_info_init(&vi); vorbis_comment_init(&vc);
    const uint8_t *head = par->extradata; int cursor = 1, lengths[3] = {0};
    for (int h = 0; h < 2; h++) { int n; do { n = head[cursor++]; lengths[h] += n; } while (n == 255); }
    lengths[2] = par->extradata_size - cursor - lengths[0] - lengths[1];
    for (int h = 0; h < 3; h++) {
      ogg_packet op = {0}; op.packet = (unsigned char *)head + cursor; op.bytes = lengths[h]; op.b_o_s = h == 0;
      CHECK(vorbis_synthesis_headerin(&vi, &vc, &op) == 0); cursor += lengths[h];
    }
    CHECK(vorbis_synthesis_init(&vd, &vi) == 0); CHECK(vorbis_block_init(&vd, &vb) == 0);
    AVPacket *packet = av_packet_alloc();
    int total = 0, packets = 0, priming = 0;
    double energy = 0, error = 0;
    while (av_read_frame(format, packet) >= 0) {
      float pcm[8192], ref[8192]; int32_t frames = -1;
      if (packets == 0) {
        CHECK(ylf_vorbis_decode(decoder, packet->data, packet->size, 0, 0, pcm, 4095, &frames) == YLFResultInvalidArgument);
        CHECK(frames == 0);
        CHECK(ylf_vorbis_decode(decoder, packet->data, 65537, 0, 0, pcm, 4096, &frames) == YLFResultInvalidArgument);
      }
      size_t sideSize = 0;
      const uint8_t *side = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &sideSize);
      uint32_t skip = side && sideSize >= 10 ? AV_RL32(side) : 0;
      uint32_t discard = side && sideSize >= 10 ? AV_RL32(side + 4) : 0;
      int result = ylf_vorbis_decode(decoder, packet->data, packet->size, skip, discard, pcm, 4096, &frames);
      CHECK(result == 0 && frames >= 0 && frames <= 4096);
      if (result != 0) break;
      if (frames == 0) priming++;
      ogg_packet op = {0}; op.packet = packet->data; op.bytes = packet->size;
      CHECK(vorbis_synthesis(&vb, &op) == 0); CHECK(vorbis_synthesis_blockin(&vd, &vb) == 0);
      float **reference = NULL; int count = vorbis_synthesis_pcmout(&vd, &reference);
      CHECK(count >= (int)(skip + discard));
      int trimmedCount = count - skip - discard;
      CHECK(trimmedCount == frames); if (trimmedCount != frames) break;
      for (int i = 0; i < frames; i++) for (int c = 0; c < channels; c++) ref[i * channels + c] = reference[c][i + skip];
      CHECK(vorbis_synthesis_read(&vd, count) == 0);
      bool finite = true;
      for (int i = 0; i < frames * channels; i++) {
        finite &= isfinite(pcm[i]); energy += ref[i] * ref[i];
        double diff = pcm[i] - ref[i]; error += diff * diff;
      }
      CHECK(finite); total += frames; packets++;
      av_packet_unref(packet);
    }
    CHECK(priming == 1);
    CHECK(total >= rate * 4 && total <= rate * 4 + 4096);

    CHECK(energy > 1 && error / energy < 0.00001);
    const uint8_t headerPacket[] = {1, 'v','o','r','b','i','s'};
    float scratch[8192]; int32_t frames = -1;
    CHECK(ylf_vorbis_decode(decoder, headerPacket, sizeof(headerPacket), 0, 0, scratch, 4096, &frames) == YLFResultReadFailed);
    CHECK(frames == 0);
    printf("Vorbis %dHz %dch pass%d: packets=%d frames=%d priming=%d SNR=%.2f dB\n",rate,channels,pass,packets,total,priming,10*log10(energy/fmax(error,1e-30)));
    vorbis_block_clear(&vb); vorbis_dsp_clear(&vd); vorbis_comment_clear(&vc); vorbis_info_clear(&vi); av_packet_free(&packet); avformat_close_input(&format);
  }
  ylf_vorbis_free(decoder); ylf_vorbis_free(NULL); ylf_vorbis_reset(NULL);
}
// Compare the resumed packets with a full linear decode at identical packet
// timestamps. Priming must happen before the requested presentation target.
static void seek_fixture(const char *path) {
  YLFMediaContextRef context = NULL; YLFMediaInfo media = {0};
  CHECK(ylf_open_local(path, &context, &media) == 0); if (!context) return;
  YLFStreamInfo stream = {0}; CHECK(ylf_copy_stream_info(context, 0, &stream) == 0);
  CHECK(stream.codec == YLFCodecVorbis);
  size_t headSize = ylf_stream_codec_config_size(context, 0);
  uint8_t *head = malloc(headSize);
  CHECK(ylf_copy_stream_codec_config(context, 0, head, headSize) == 0);
  YLFVorbisDecoderRef decoder = ylf_vorbis_create(head, headSize, stream.sample_rate, stream.channel_count);
  free(head); CHECK(decoder != NULL); if (!decoder) { ylf_close(&context); return; }
  struct Entry { int64_t pts; int frames; float *pcm; } entries[4096] = {0};
  int count = 0; YLFPacketRef packet = NULL;
  while (ylf_read_packet(context, &packet) == 0) {
    float pcm[8192]; int32_t frames = 0; uint32_t skip = 0, discard = 0;
    CHECK(ylf_packet_audio_trim(packet, &skip, &discard) == 0);
    CHECK(ylf_vorbis_decode(decoder, ylf_packet_data(packet), ylf_packet_size(packet), skip, discard, pcm, 4096, &frames) == 0);
    CHECK(count < 4096); if (count >= 4096) { ylf_packet_release(&packet); break; }
    entries[count].pts = ylf_packet_pts_us(packet); entries[count].frames = frames;
    entries[count].pcm = malloc(frames * stream.channel_count * sizeof(float));
    if (frames) memcpy(entries[count].pcm, pcm, frames * stream.channel_count * sizeof(float));
    count++; ylf_packet_release(&packet);
  }
  const int64_t targets[] = {2000000,1250000,0};
  for (int target = 0; target < 3; target++) {
    CHECK(ylf_seek(context, targets[target]) == 0); ylf_vorbis_reset(decoder);
    int matched = 0, packets = 0; int64_t firstPTS = INT64_MAX;
    while (matched < 3 && ylf_read_packet(context, &packet) == 0) {
      int64_t pts = ylf_packet_pts_us(packet); if (!packets++) firstPTS = pts;
      float pcm[8192]; int32_t frames = 0; uint32_t skip = 0, discard = 0;
      CHECK(ylf_packet_audio_trim(packet, &skip, &discard) == 0);
      CHECK(ylf_vorbis_decode(decoder, ylf_packet_data(packet), ylf_packet_size(packet), skip, discard, pcm, 4096, &frames) == 0);
      if (frames && pts >= targets[target]) {
        int index = 0; while (index < count && entries[index].pts != pts) index++;
        CHECK(index < count);
        if (index < count) {
          CHECK(frames == entries[index].frames);
          if (frames == entries[index].frames) CHECK(memcmp(entries[index].pcm, pcm, frames * stream.channel_count * sizeof(float)) == 0);
        }
        matched++;
      }
      ylf_packet_release(&packet);
    }
    CHECK(matched == 3);
    CHECK(firstPTS <= (targets[target] > 0 ? targets[target] - 200000 : 0));
    if (!targets[target]) CHECK(firstPTS == entries[0].pts);
    printf("Vorbis seek target=%lld first=%lld matched=%d\n",(long long)targets[target],(long long)firstPTS,matched);
  }
  for (int i = 0; i < count; i++) free(entries[i].pcm);
  ylf_vorbis_free(decoder); ylf_close(&context);
  CHECK(ylf_debug_outstanding_packet_count() == 0);
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    CHECK(argc == 2); if (argc == 2) { fixture(argv[1]); seek_fixture(argv[1]); }
    printf("Vorbis bridge: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
  }
}
