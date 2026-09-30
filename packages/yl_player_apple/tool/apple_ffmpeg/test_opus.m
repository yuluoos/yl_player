#import <Foundation/Foundation.h>
#include <math.h>
#include <libavutil/intreadwrite.h>
#ifdef YL_OPUS_ARTIFACT
#include "YlFFmpegBridge.h"
#include <libavformat/avformat.h>
#include <libavutil/intreadwrite.h>
#else
#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
#endif

static int checks, failures;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c); } } while (0)

// The reference is decoded by the independently installed libopus decoder,
// not the minimal production FFmpeg's native Opus decoder.
static void check_fixture(const char *path, const char *reference, int channels) {
  AVFormatContext *format = NULL;
  CHECK(avformat_open_input(&format, path, NULL, NULL) == 0);
  if (!format) return;
  int index = -1;
  for (unsigned i = 0; i < format->nb_streams; i++)
    if (format->streams[i]->codecpar->codec_id == AV_CODEC_ID_OPUS) index = (int)i;
  CHECK(index >= 0);
  if (index < 0) { avformat_close_input(&format); return; }
  AVCodecParameters *par = format->streams[index]->codecpar;
  YLFOpusDecoderRef decoder = ylf_opus_create(par->extradata, par->extradata_size);
  CHECK(decoder != NULL);
  if (!decoder) { avformat_close_input(&format); return; }
  FILE *expected = fopen(reference, "rb");
  CHECK(expected != NULL);
  if (!expected) { ylf_opus_free(decoder); avformat_close_input(&format); return; }
  AVPacket *packet = av_packet_alloc();
  int total = 0, packets = 0, trimmedStart = 0, trimmedEnd = 0;
  double squaredError = 0, referenceEnergy = 0;
  // Container CodecDelay is authoritative here; callers pass explicit trim.
  uint32_t initialSkip = par->initial_padding;
  while (av_read_frame(format, packet) >= 0) {
    if (packet->stream_index == index) {
      size_t sideSize = 0;
      const uint8_t *side = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &sideSize);
      uint32_t skip = side && sideSize >= 10 ? AV_RL32(side) : 0;
      uint32_t discard = side && sideSize >= 10 ? AV_RL32(side + 4) : 0;
      if (strstr(path, "speech-")) {
        float pcm[5760 * 2]; int32_t frames = -1, offset = -1;
        CHECK((packet->data[0] >> 3) < 16);
        CHECK(ylf_opus_decode(decoder, packet->data, packet->size, 0, 0,
                             pcm, 5760, &frames, &offset) == YLFResultAudioConfigurationUnsupported);
        CHECK(frames == 0 && offset == 0);
        printf("Opus %dch SILK/hybrid: explicitly rejected before consumption\n", channels);
        fclose(expected); av_packet_free(&packet); ylf_opus_free(decoder);
        avformat_close_input(&format); return;
      }
      if (packets == 0 && skip == 0) skip = initialSkip;
      if (packets == 0) {
        YLFOpusDecoderRef resetDecoder = ylf_opus_create(par->extradata, par->extradata_size);
        float fresh[5760 * 2], reset[5760 * 2]; int32_t n1 = 0, n2 = 0, off = 0;
        CHECK(ylf_opus_decode(resetDecoder, packet->data, packet->size, 0, 0, fresh, 5760, &n1, &off) == 0);
        CHECK(ylf_opus_decode(resetDecoder, packet->data, packet->size, 0, 0, reset, 5760, &n2, &off) == 0);
        ylf_opus_reset(resetDecoder);
        CHECK(ylf_opus_decode(resetDecoder, packet->data, packet->size, 0, 0, reset, 5760, &n2, &off) == 0);
        CHECK(n1 == n2 && memcmp(fresh, reset, n1 * channels * sizeof(float)) == 0);
        ylf_opus_reset(resetDecoder);
        CHECK(ylf_opus_decode(resetDecoder, packet->data, packet->size, n1, 1, reset, 5760, &n2, &off) == YLFResultInvalidArgument);
        CHECK(n2 == 0 && off == 0);
        CHECK(ylf_opus_decode(resetDecoder, packet->data, packet->size, 0, 0, reset, 5760, &n2, &off) == 0);
        CHECK(n1 == n2 && memcmp(fresh, reset, n1 * channels * sizeof(float)) == 0);
        ylf_opus_free(resetDecoder);
      }
      float pcm[5760 * 2], referencePCM[5760 * 2];
      int32_t frames = -1, offset = -1;
      int result = ylf_opus_decode(decoder, packet->data, packet->size, skip, discard,
                                  pcm, 5760, &frames, &offset);
      CHECK(result == 0 && frames >= 0 && frames <= 5760);
      if (result != 0) break;
      CHECK(offset >= 0 && offset <= 5760);
      size_t readFrames = fread(referencePCM, sizeof(float) * channels, frames, expected);
      CHECK(readFrames == (size_t)frames);
      if (readFrames != (size_t)frames) break;
      bool finite = true;
      for (int i = 0; i < frames * channels; i++) {
        finite = finite && isfinite(pcm[i]);
        double diff = pcm[i] - referencePCM[i];
        squaredError += diff * diff; referenceEnergy += referencePCM[i] * referencePCM[i];
      }
      CHECK(finite);
      total += frames; packets++; trimmedStart += offset; trimmedEnd += discard;
    }
    av_packet_unref(packet);
  }
  CHECK(total == 192000);
  CHECK(trimmedStart == (int)initialSkip && trimmedStart > 0);
  // 2.5 ms fixtures end exactly at a packet boundary (no tail padding).
  if (strstr(path, "20-")) CHECK(trimmedEnd > 0);
  CHECK(fgetc(expected) == EOF);
  CHECK(referenceEnergy > 1);
  CHECK(squaredError / referenceEnergy < 0.00001);
  printf("Opus %dch: packets=%d frames=%d skip=%d padding=%d SNR=%.2f dB\n",
         channels, packets, total, trimmedStart, trimmedEnd,
         10 * log10(referenceEnergy / fmax(squaredError, 1e-30)));
  fclose(expected); av_packet_free(&packet); ylf_opus_free(decoder);
  avformat_close_input(&format);
}

static void check_contract(void) {
  uint8_t head[19] = {'O','p','u','s','H','e','a','d',1,2,56,1,128,187,0,0,0,0,0};
  CHECK(ylf_opus_create(NULL, 19) == NULL);
  CHECK(ylf_opus_create(head, 18) == NULL);
  CHECK(ylf_opus_create(head, 20) == NULL);
  head[8] = 16; CHECK(ylf_opus_create(head, 19) == NULL); head[8] = 1;
  head[9] = 0; CHECK(ylf_opus_create(head, 19) == NULL);
  head[9] = 3; CHECK(ylf_opus_create(head, 19) == NULL); head[9] = 2;
  head[18] = 1; CHECK(ylf_opus_create(head, 19) == NULL); head[18] = 0;
  YLFOpusDecoderRef decoder = ylf_opus_create(head, 19);
  CHECK(decoder != NULL);
  float pcm[5760 * 2]; int32_t frames = -1, offset = -1;
  // RFC 6716 3.1 valid three-byte CELT silence packet (20 ms).
  const uint8_t silence[] = {0xfc, 0xff, 0xfe};
  CHECK(ylf_opus_decode(decoder, silence, 3, 0, 0, pcm, 5760, &frames, &offset) == 0);
  CHECK(frames == 960 && offset == 0);
  CHECK(ylf_opus_decode(decoder, silence, 3, 312, 48, pcm, 5760, &frames, &offset) == 0);
  CHECK(frames == 600 && offset == 312);
  // Skip carries over full packets; reset removes it and codec history.
  CHECK(ylf_opus_decode(decoder, silence, 3, 1200, 0, pcm, 5760, &frames, &offset) == 0);
  CHECK(frames == 0 && offset == 960);
  CHECK(ylf_opus_decode(decoder, silence, 3, 0, 0, pcm, 5760, &frames, &offset) == 0);
  CHECK(frames == 720 && offset == 240);
  ylf_opus_reset(decoder);
  CHECK(ylf_opus_decode(decoder, silence, 3, 0, 960, pcm, 5760, &frames, &offset) == 0);
  CHECK(frames == 0);
  CHECK(ylf_opus_decode(decoder, silence, 3, 0, 961, pcm, 5760, &frames, &offset) != 0);
  CHECK(ylf_opus_decode(decoder, silence, 3, UINT32_MAX, 0, pcm, 5760, &frames, &offset) != 0);
  CHECK(ylf_opus_decode(decoder, silence, 3, 0, 0, pcm, 959, &frames, &offset) != 0);
  CHECK(ylf_opus_decode(decoder, silence, SIZE_MAX, 0, 0, pcm, 5760, &frames, &offset) != 0);
  CHECK(ylf_opus_decode(decoder, NULL, 3, 0, 0, pcm, 5760, &frames, &offset) != 0);
  CHECK(ylf_opus_decode(decoder, silence, 0, 0, 0, pcm, 5760, &frames, &offset) != 0);
  const uint8_t malformed[] = {0xff, 0x3f}; // 63 frames exceed 120 ms.
  CHECK(ylf_opus_decode(decoder, malformed, 2, 0, 0, pcm, 5760, &frames, &offset) != 0);
  ylf_opus_reset(decoder);
  CHECK(ylf_opus_decode(decoder, silence, 3, 0, 0, pcm, 5760, &frames, &offset) == 0);
  CHECK(frames == 960 && offset == 0);
  for (int config = 0; config < 16; config++) {
    const uint8_t unsupported[] = {(uint8_t)(config << 3), 0xff, 0xfe};
    CHECK(ylf_opus_decode(decoder, unsupported, 3, 0, 0, pcm, 5760, &frames, &offset) == YLFResultAudioConfigurationUnsupported);
  }
  ylf_opus_free(decoder); ylf_opus_free(NULL); ylf_opus_reset(NULL);
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    CHECK(argc == 5);
    if (argc != 5) return 1;
    check_contract(); check_fixture(argv[1], argv[2], 1); check_fixture(argv[3], argv[4], 2);
    printf("Opus bridge: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
  }
}
