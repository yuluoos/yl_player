// Native demux metadata regression. Fixtures are synthetic, never user media.
#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"

static int failures = 0;
static int checks = 0;
#define CHECK(condition, message) do { \
  checks++; \
  if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); failures++; } \
} while (0)

static void check_fixture(const char *path, int32_t codec, int32_t channels) {
  YLFMediaContextRef context = NULL;
  YLFMediaInfo info = {0};
  CHECK(ylf_open_local(path, &context, &info) == YLFResultOK, "open encoded audio fixture");
  if (!context) return;
  int audio_count = 0;
  for (int32_t i = 0; i < info.stream_count; i++) {
    YLFStreamInfo stream = {0};
    CHECK(ylf_copy_stream_info(context, i, &stream) == YLFResultOK, "read stream metadata");
    if (stream.kind != YLFStreamAudio) continue;
    audio_count++;
    CHECK(stream.codec == codec, "encoded Dolby audio codec recognized");
    CHECK(stream.sample_rate == 48000, "encoded Dolby sample rate preserved");
    CHECK(stream.channel_count == channels, "encoded Dolby channel count preserved");
    CHECK(stream.channel_layout_mask == (channels == 2 ? AV_CH_LAYOUT_STEREO : AV_CH_LAYOUT_5POINT1), "parsed Dolby speaker roles preserved");
  }
  CHECK(audio_count == 1, "exactly one audio track in fixture");
  YLFPacketRef packet = NULL;
  int audio_packets = 0;
  while (audio_packets < 2 && ylf_read_packet(context, &packet) == YLFResultOK) {
    YLFStreamInfo stream = {0};
    ylf_copy_stream_info(context, ylf_packet_stream_index(packet), &stream);
    if (stream.kind == YLFStreamAudio) {
      CHECK(ylf_packet_duration_us(packet) == 32000, "Dolby packet duration is 1536 samples at 48 kHz");
      audio_packets++;
    }
    ylf_packet_release(&packet);
  }
  CHECK(audio_packets == 2, "read encoded audio packets");
  ylf_close(&context);
  CHECK(context == NULL, "fixture context released");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    CHECK(ylf_codec(AV_CODEC_ID_AC3) == 6, "AC-3 stable bridge codec ID");
    CHECK(ylf_codec(AV_CODEC_ID_EAC3) == 7, "E-AC-3 stable bridge codec ID");
    CHECK(ylf_codec(AV_CODEC_ID_AAC) == YLFCodecAAC, "AAC mapping unchanged");
    CHECK(ylf_codec(AV_CODEC_ID_DTS) == YLFCodecDTS, "DTS mapping unchanged");
    CHECK(ylf_codec(AV_CODEC_ID_FLAC) == 8, "FLAC stable bridge codec ID");
    CHECK(ylf_codec(AV_CODEC_ID_VORBIS) == YLFCodecUnsupported, "unimplemented codec stays unsupported");
    if (argc != 3 && argc != 4) {
      fprintf(stderr, "usage: test_audio_codecs AC3_MKV EAC3_MKV [REAL_EAC3_MKV]\n");
      return 2;
    }
    check_fixture(argv[1], YLFCodecAC3, 2);
    check_fixture(argv[2], YLFCodecEAC3, 6);
    if (argc == 4) check_fixture(argv[3], YLFCodecEAC3, 6);
    struct YLFMediaContext synthetic = {0};
    synthetic.format = avformat_alloc_context();
    AVStream *unknown = avformat_new_stream(synthetic.format, NULL);
    unknown->codecpar->ch_layout.order = AV_CHANNEL_ORDER_UNSPEC;
    unknown->codecpar->ch_layout.nb_channels = 6;
    YLFStreamInfo unknownInfo = {0};
    CHECK(ylf_copy_stream_info(&synthetic, 0, &unknownInfo) == YLFResultOK && unknownInfo.channel_layout_mask == 0, "unspecified channels never produce invented speaker roles");
    avformat_free_context(synthetic.format);
    CHECK(ylf_debug_outstanding_packet_count() == 0, "no leaked demux packets");
    fprintf(stderr, "Audio codec regression: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
  }
}
