// Owned TS fixture: verify public time zero, audio/video skew, sample timing and seeks.
#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
static int failures = 0, checks = 0;
#define CHECK(c,m) do { checks++; if (!(c)) { failures++; fprintf(stderr,"FAIL: %s\n",m); } } while (0)
static int64_t fake_hls_seek(void *opaque, int64_t time) { return time; }
static void check_clock_boundaries(void) {
  struct YLFMediaContext context = {0};
  context.format = avformat_alloc_context();
  AVStream *stream = avformat_new_stream(context.format,NULL);
  stream->time_base = AV_TIME_BASE_Q;
  struct YLFPacket packet = {.owner = &context, .value = av_packet_alloc()};
  packet.value->pts = 100; packet.value->dts = -100;
  CHECK(ylf_packet_pts_us(&packet)==100 && ylf_packet_dts_us(&packet)==-100,"default timeline unchanged, including negative DTS");
  context.timeline_origin_us = 200;
  CHECK(ylf_packet_pts_us(&packet)==-100 && ylf_packet_dts_us(&packet)==-300,"signed origin subtraction preserves ordering");
  packet.value->pts = AV_NOPTS_VALUE;
  CHECK(ylf_packet_pts_us(&packet)==INT64_MIN,"missing PTS stays missing");
  packet.value->pts = INT64_MAX; context.timeline_origin_us = -1;
  CHECK(ylf_packet_pts_us(&packet)==INT64_MIN,"timestamp subtraction overflow rejected");
  av_packet_free(&packet.value);avformat_free_context(context.format);
}
int main(int argc, const char **argv) { @autoreleasepool {
  check_clock_boundaries();
  if (argc != 3) return 2;
  YLFMediaContextRef context = NULL; YLFMediaInfo info = {0};
  CHECK(ylf_open_local(argv[1], &context, &info) == YLFResultOK, "open TS");
  if (!context) return 1;
  CHECK(context->format->start_time == 1400000, "independently probed source origin");
  CHECK(info.duration_us > 3900000 && info.duration_us < 4100000, "duration excludes source origin");
  context->time_seek_callback = fake_hls_seek;
  CHECK(ylf_use_relative_transport_stream_timestamps(context)==YLFResultUnsupportedContainer && context->timeline_origin_us==0,"HLS timestamp ownership unchanged");
  context->time_seek_callback = NULL;
  CHECK(ylf_use_relative_transport_stream_timestamps(context)==YLFResultOK, "enable relative TS timeline");
  CHECK(ylf_seek(context,INT64_MAX)==YLFResultSeekFailed, "seek addition overflow rejected");
  int64_t firstAudio = INT64_MIN, firstVideo = INT64_MIN;
  for (int i = 0; i < 80 && (firstAudio == INT64_MIN || firstVideo == INT64_MIN); i++) {
    YLFPacketRef packet = NULL;
    CHECK(ylf_read_packet(context, &packet) == YLFResultOK, "read packet");
    if (!packet) break;
    YLFStreamInfo stream = {0}; ylf_copy_stream_info(context, ylf_packet_stream_index(packet), &stream);
    int64_t pts = ylf_packet_pts_us(packet);
    CHECK(ylf_use_relative_transport_stream_timestamps(context)==YLFResultUnsupportedContainer,"cannot change timeline while packets are owned");
    if (stream.kind == YLFStreamAudio && firstAudio == INT64_MIN) firstAudio = pts;
    if (stream.kind == YLFStreamVideo && firstVideo == INT64_MIN) {
      firstVideo = pts;
      CMVideoFormatDescriptionRef format = NULL; CMSampleBufferRef sample = NULL;
      CHECK(ylf_copy_video_format_description(context, stream.index, &format) == YLFResultOK, "video config");
      if (format) {
        CHECK(ylf_create_video_sample_buffer(&packet, format, &sample) == YLFResultOK, "sample buffer");
        if (sample) {
          CHECK(llround(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))*1000000) == pts, "sample and packet PTS agree");
          CFRelease(sample);
        }
        CFRelease(format);
      }
    }
    ylf_packet_release(&packet);
  }
  CHECK(firstAudio == 0, "audio starts at relative zero");
  CHECK(firstVideo > 0 && firstVideo < 10000, "video preserves small relative AV skew");
  int64_t targets[] = {2000000, 1250000, 0};
  for (int t = 0; t < 3; t++) {
    int64_t target = targets[t];
    CHECK(ylf_seek(context,target) == YLFResultOK, "relative seek forward/backward");
    int64_t first = INT64_MIN;
    for (int i=0;i<100;i++) {
      YLFPacketRef packet=NULL; if(ylf_read_packet(context,&packet)!=YLFResultOK)break;
      YLFStreamInfo stream={0};ylf_copy_stream_info(context,ylf_packet_stream_index(packet),&stream);
      if(stream.kind==YLFStreamVideo && ylf_packet_is_keyframe(packet)){first=ylf_packet_pts_us(packet);ylf_packet_release(&packet);break;}
      ylf_packet_release(&packet);
    }
    CHECK(first >= target-1100000 && first <= target+6000, "seek starts decoding from a keyframe at/before the requested media time");
  }
  ylf_close(&context);
  CHECK(ylf_open_local(argv[2], &context, &info)==YLFResultOK, "open owned sparse-keyframe TS");
  if (context) {
    CHECK(ylf_use_relative_transport_stream_timestamps(context)==YLFResultOK, "enable sparse-keyframe timeline");
    CHECK(ylf_seek(context,10000000)==YLFResultSeekFailed, "bounded search rejects missing prior keyframe instead of overshooting");
    CHECK(ylf_seek(context,0)==YLFResultOK, "can seek to initial keyframe after failed bounded search");
    ylf_close(&context);
  }
  CHECK(ylf_debug_outstanding_packet_count()==0,"packets released");
  fprintf(stderr,"TS timeline: %d checks, %d failures\n",checks,failures);
  return failures ? 1 : 0;
}}
