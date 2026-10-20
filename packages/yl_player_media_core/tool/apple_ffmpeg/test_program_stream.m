// Owned PS/AVC/MP3: exercise file and caller-owned AVIO with real compressed samples.
#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
static int failures, checks;
#define CHECK(c,m) do { checks++; if (!(c)) { failures++; fprintf(stderr,"FAIL: %s\n",m); } } while (0)
typedef struct { const uint8_t *bytes; int64_t size, cursor; bool cancelled, reject_seek; int cancels; } Input;
static int32_t read_input(void *opaque, uint8_t *buffer, int32_t capacity) {
  Input *input=opaque;
  if(input->cancelled)return YLFCallbackCancelled;
  int count=(int)FFMIN(1024,FFMIN(capacity,input->size-input->cursor));
  memcpy(buffer,input->bytes+input->cursor,count);input->cursor+=count;return count;
}
static int64_t seek_input(void *opaque,int64_t offset,int32_t whence) {
  Input *input=opaque;
  if(input->cancelled)return YLFCallbackCancelled;
  if(whence==AVSEEK_SIZE)return input->size;
  if(input->reject_seek)return YLFCallbackSeekUnsupported;
  int64_t base=whence==SEEK_SET?0:whence==SEEK_CUR?input->cursor:whence==SEEK_END?input->size:-1;
  if(base<0||offset>INT64_MAX-base||offset < -base||base+offset>input->size)return YLFCallbackError;
  return input->cursor=base+offset;
}
static void cancel_input(void *opaque) { ((Input *)opaque)->cancels++; }
static void check_media(YLFMediaContextRef context) {
  CHECK(context->format->start_time>0,"source clock has a nonzero origin");
  CHECK(ylf_use_relative_transport_stream_timestamps(context)==YLFResultOK,"enable relative PS timeline");
  CHECK(ylf_seek(context,INT64_MAX)==YLFResultSeekFailed,"seek overflow is rejected");
  int video_frames=0; int64_t previous=INT64_MIN;
  for (;;) {
    YLFPacketRef packet=NULL;int result=ylf_read_packet(context,&packet);
    if(result!=YLFResultOK){CHECK(result==YLFResultEOF,"full PS packet read reaches clean EOF");break;}
    YLFStreamInfo stream={0};ylf_copy_stream_info(context,ylf_packet_stream_index(packet),&stream);
    if(stream.kind==YLFStreamVideo) {
      int64_t pts=ylf_packet_pts_us(packet);
      if(video_frames<3 || pts<=previous)fprintf(stderr,"PS video index=%d pts=%lld duration=%lld profile=%d delay=%d fps=%d/%d\n",video_frames,(long long)pts,(long long)ylf_packet_duration_us(packet),context->format->streams[stream.index]->codecpar->profile,context->format->streams[stream.index]->codecpar->video_delay,context->format->streams[stream.index]->codecpar->framerate.num,context->format->streams[stream.index]->codecpar->framerate.den);
      CHECK(pts!=INT64_MIN && pts>previous,"every PS AVC frame has ordered presentation time");
      previous=pts;video_frames++;
    }
    ylf_packet_release(&packet);
  }
  CHECK(video_frames==96,"all four seconds of PS AVC are demuxed");
  int64_t targets[]={0,2000000,1250000,0};
  for(int t=0;t<4;t++) {
    CHECK(ylf_seek(context,targets[t])==YLFResultOK,"PS seek");
    bool found=false;
    for(int i=0;i<256;i++) {
      YLFPacketRef packet=NULL;if(ylf_read_packet(context,&packet)!=YLFResultOK)break;
      YLFStreamInfo stream={0};ylf_copy_stream_info(context,ylf_packet_stream_index(packet),&stream);
      if(stream.kind==YLFStreamVideo && ylf_packet_is_keyframe(packet)) {
        int64_t pts=ylf_packet_pts_us(packet);
        CHECK(stream.codec==YLFCodecH264,"PS AVC stream");
        fprintf(stderr,"PS seek target=%lld first_keyframe=%lld\n",(long long)targets[t],(long long)pts);
        CHECK(pts>=FFMAX(0,targets[t]-1100000) && pts<=targets[t]+30000,"PS bounded preceding keyframe with preserved AV skew");
        CMVideoFormatDescriptionRef format=NULL;CMSampleBufferRef sample=NULL;
        CHECK(ylf_copy_video_format_description(context,stream.index,&format)==YLFResultOK,"PS AVC configuration");
        if(format) {
          CHECK(ylf_create_video_sample_buffer(&packet,format,&sample)==YLFResultOK,"PS sample creation");
          if(sample) { CHECK(llround(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))*1000000)==pts,"sample uses relative PTS");CFRelease(sample); }
          CFRelease(format);
        }
        found=true;ylf_packet_release(&packet);break;
      }
      ylf_packet_release(&packet);
    }
    CHECK(found,"PS video available after seek");
  }
}
int main(int argc,const char **argv) { @autoreleasepool {
  if(argc!=2)return 2;
  YLFMediaContextRef context=NULL;YLFMediaInfo info={0};
  CHECK(ylf_open_local(argv[1],&context,&info)==YLFResultOK,"open PS file");
  if(context){check_media(context);ylf_close(&context);}
  NSData *data=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
  CHECK(data.length>32,"owned fixture available");
  Input input={.bytes=data.bytes,.size=data.length};
  CHECK(ylf_open_callbacks(&input,read_input,seek_input,cancel_input,&context,&info)==YLFResultOK,"open PS custom AVIO");
  if(context) {
    check_media(context);
    // Drain beyond the cached seek window so a byte seek is actually needed.
    for (;;) { YLFPacketRef packet=NULL; int result=ylf_read_packet(context,&packet); ylf_packet_release(&packet); if(result!=YLFResultOK)break; }
    input.reject_seek=true;
    CHECK(ylf_seek(context,1000000)!=YLFResultOK,"failed caller seek cannot report success");
    ylf_close(&context);
  }
  CHECK(input.cancels==1,"custom input closed once");
  input=(Input){.bytes=data.bytes,.size=data.length,.cancelled=true};
  CHECK(ylf_open_callbacks(&input,read_input,seek_input,cancel_input,&context,&info)==YLFResultCallbackCancelled,"cancelled input remains cancelled");
  CHECK(context==NULL,"failed open publishes no context");
  input=(Input){.bytes=data.bytes,.size=12};
  CHECK(ylf_open_callbacks(&input,read_input,seek_input,cancel_input,&context,&info)!=YLFResultOK,"truncated pack is not playable");
  CHECK(context==NULL,"truncated open publishes no context");
  CHECK(ylf_debug_outstanding_packet_count()==0,"PS packets released");
  fprintf(stderr,"PS regression: %d checks, %d failures\n",checks,failures);
  return failures?1:0;
}}
