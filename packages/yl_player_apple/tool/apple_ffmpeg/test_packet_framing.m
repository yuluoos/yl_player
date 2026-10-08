// Exercise framing at the real sample-buffer boundary, including byte collisions.
#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
static int checks = 0, failures = 0;
#define CHECK(c,m) do { checks++; if (!(c)) { failures++; fprintf(stderr,"FAIL: %s\n",m); } } while (0)
static void check_case(YLFMediaContextRef context, enum AVCodecID codec,
    int configMode, const uint8_t *input, size_t size,
    const uint8_t *expected, size_t expectedSize, bool success) {
  YLFPacketRef packet = NULL;
  CHECK(ylf_read_packet(context, &packet) == YLFResultOK, "owned packet available");
  if (!packet) return;
  AVCodecParameters *par = context->format->streams[0]->codecpar;
  enum AVCodecID oldCodec = par->codec_id;
  uint8_t *oldConfig = par->extradata; int oldSize = par->extradata_size;
  uint8_t config[] = { configMode == 1 ? 1 : 0, 0, 1, 0x67 };
  par->codec_id = codec; par->extradata = configMode < 0 ? NULL : config;
  par->extradata_size = configMode < 0 ? 0 : sizeof(config);
  av_packet_unref(packet->value);
  CHECK(av_new_packet(packet->value, (int)size) == 0, "allocate packet bytes");
  memcpy(packet->value->data, input, size); packet->value->stream_index = 0;
  packet->value->pts = 0; packet->value->dts = 0; packet->value->duration = 1;
  CMVideoFormatDescriptionRef format = NULL;
  CMVideoCodecType type = codec == AV_CODEC_ID_HEVC ? kCMVideoCodecType_HEVC
      : codec == AV_CODEC_ID_VP9 ? kCMVideoCodecType_VP9 : kCMVideoCodecType_H264;
  CHECK(CMVideoFormatDescriptionCreate(NULL, type, 320, 180, NULL, &format) == noErr, "sample format");
  CMSampleBufferRef sample = NULL;
  int32_t status = ylf_create_video_sample_buffer(&packet, format, &sample);
  CHECK((status == YLFResultOK) == success, "framing result");
  if (success && sample) {
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t count = CMBlockBufferGetDataLength(block);
    NSMutableData *bytes = [NSMutableData dataWithLength:count];
    CHECK(CMBlockBufferCopyDataBytes(block, 0, count, bytes.mutableBytes) == noErr, "read sample bytes");
    CHECK(count == expectedSize && memcmp(bytes.bytes, expected, expectedSize) == 0, "sample preserves declared framing");
    CHECK(packet == NULL, "sample takes packet ownership");
  } else if (!success) { CHECK(packet != NULL && sample == NULL, "failed conversion preserves caller ownership"); }
  if (sample) CFRelease(sample);
  if (format) CFRelease(format);
  ylf_packet_release(&packet);
  par->codec_id = oldCodec; par->extradata = oldConfig; par->extradata_size = oldSize;
  CHECK(ylf_debug_outstanding_packet_count() == 0, "packet lifetime balanced");
}
int main(int argc, const char **argv) { @autoreleasepool {
  if (argc != 2) return 2;
  YLFMediaContextRef context = NULL; YLFMediaInfo info = {0};
  CHECK(ylf_open_local(argv[1], &context, &info) == YLFResultOK, "open fixture");
  if (!context) return 2;
  for (int codecIndex = 0; codecIndex < 2; codecIndex++) {
    enum AVCodecID codec = codecIndex ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264;
    const int lengths[] = {1, 255, 256, 289, 511, 512};
    for (int i = 0; i < 6; i++) {
      size_t length = (size_t)lengths[i]; uint8_t data[516];
      memset(data, 0x65, sizeof(data)); AV_WB32(data, length);
      check_case(context, codec, 1, data, length + 4, data, length + 4, true);
    }
    uint8_t annex[] = {0,0,1,0x65,0x88,0,0,0,1,0x61,0x99};
    uint8_t prefixed[] = {0,0,0,2,0x65,0x88,0,0,0,2,0x61,0x99};
    check_case(context, codec, 0, annex, sizeof(annex), prefixed, sizeof(prefixed), true);
    check_case(context, codec, -1, annex, sizeof(annex), prefixed, sizeof(prefixed), true);
    uint8_t empty[] = {0,0,0,1};
    check_case(context, codec, 0, empty, sizeof(empty), NULL, 0, false);
  }
  uint8_t opaque[] = {0,0,1,0x65,0x88};
  check_case(context, AV_CODEC_ID_VP9, 0, opaque, sizeof(opaque), opaque, sizeof(opaque), true);
  ylf_close(&context);
  fprintf(stderr,"packet framing: %d checks, %d failures\n",checks,failures);
  return failures ? 1 : 0;
}}
