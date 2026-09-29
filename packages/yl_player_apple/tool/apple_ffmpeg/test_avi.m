// Owned AVC/MP3 AVI, with and without idx1: timing, compressed samples and seek anchors.
#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
static int failures = 0, checks = 0;
#define CHECK(c,m) do { checks++; if (!(c)) { failures++; fprintf(stderr,"FAIL: %s\n",m); } } while (0)
static void check_file(const char *path) {
  YLFMediaContextRef context = NULL; YLFMediaInfo info = {0};
  CHECK(ylf_open_local(path, &context, &info)==YLFResultOK,"open AVI");
  if (!context) return;
  CHECK(info.duration_us > 3900000 && info.duration_us < 4200000,"AVI duration");
  int64_t targets[] = {0,2000000,1250000,0};
  for (int t=0;t<4;t++) {
    CHECK(ylf_seek(context,targets[t])==YLFResultOK,"AVI seek");
    bool found=false;
    for(int i=0;i<200;i++) {
      YLFPacketRef packet=NULL;if(ylf_read_packet(context,&packet)!=YLFResultOK)break;
      YLFStreamInfo stream={0};ylf_copy_stream_info(context,ylf_packet_stream_index(packet),&stream);
      if(stream.kind==YLFStreamVideo) {
        int64_t pts=ylf_packet_pts_us(packet);
        CHECK(pts!=INT64_MIN,"AVI video has usable presentation time");
        // The production demux gate discards preroll packets until a keyframe.
        if (!ylf_packet_is_keyframe(packet)) { ylf_packet_release(&packet); continue; }
        CHECK(pts >= FFMAX(0,targets[t]-8000000) && pts <= targets[t]+50000,"AVI keyframe at or before target within bounded lookback");
        CMVideoFormatDescriptionRef format=NULL;CMSampleBufferRef sample=NULL;
        CHECK(ylf_copy_video_format_description(context,stream.index,&format)==YLFResultOK,"AVI AVC format");
        if(format) {
          CHECK(ylf_create_video_sample_buffer(&packet,format,&sample)==YLFResultOK,"AVI compressed video sample");
          if(sample) { CHECK(CMTIME_IS_VALID(CMSampleBufferGetPresentationTimeStamp(sample)),"AVI sample has valid presentation time");CFRelease(sample); }
          CFRelease(format);
        }
        found=true;ylf_packet_release(&packet);break;
      }
      ylf_packet_release(&packet);
    }
    CHECK(found,"AVI video read after seek");
  }
  ylf_close(&context);
}
static void check_missing_timestamp_policy(void) {
  AVFormatContext *format=avformat_alloc_context();
  format->iformat=av_find_input_format("avi");
  AVStream *stream=avformat_new_stream(format,NULL);
  AVCodecParameters *par=stream->codecpar;
  par->codec_type=AVMEDIA_TYPE_VIDEO;par->codec_id=AV_CODEC_ID_H264;
  par->profile=AV_PROFILE_H264_CONSTRAINED_BASELINE;par->video_delay=0;
  AVPacket *packet=av_packet_alloc();packet->pts=AV_NOPTS_VALUE;packet->dts=42;
  CHECK(ylf_normalize_avi_timing(format,packet) && packet->pts==42,"Baseline AVC may use DTS");
  packet->pts=AV_NOPTS_VALUE;par->video_delay=1;
  CHECK(!ylf_normalize_avi_timing(format,packet),"reordered AVI cannot invent PTS");
  par->video_delay=0;par->profile=AV_PROFILE_H264_HIGH;
  CHECK(!ylf_normalize_avi_timing(format,packet),"High profile missing PTS remains unsupported");
  par->profile=AV_PROFILE_UNKNOWN;
  CHECK(!ylf_normalize_avi_timing(format,packet),"unknown profile cannot invent PTS");
  par->profile=AV_PROFILE_H264_BASELINE;packet->dts=AV_NOPTS_VALUE;
  CHECK(!ylf_normalize_avi_timing(format,packet),"missing DTS cannot invent PTS");
  packet->pts=99;par->profile=AV_PROFILE_H264_HIGH;
  CHECK(ylf_normalize_avi_timing(format,packet) && packet->pts==99,"explicit PTS remains authoritative");
  packet->pts=AV_NOPTS_VALUE;format->iformat=av_find_input_format("mpegts");
  CHECK(ylf_normalize_avi_timing(format,packet) && packet->pts==AV_NOPTS_VALUE,"other containers unchanged");
  av_packet_free(&packet);avformat_free_context(format);
}
int main(int argc,const char **argv) { @autoreleasepool {
  if(argc!=3)return 2;
  check_missing_timestamp_policy();
  check_file(argv[1]);check_file(argv[2]);
  CHECK(ylf_debug_outstanding_packet_count()==0,"AVI packets released");
  fprintf(stderr,"AVI regression: %d checks, %d failures\n",checks,failures);
  return failures?1:0;
}}
