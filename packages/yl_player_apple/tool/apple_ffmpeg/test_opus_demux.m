#include <libavutil/intreadwrite.h>
#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
static int checks, failures;
#define CHECK(x) do { checks++; if (!(x)) { failures++; fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); } } while(0)
int main(int argc, const char **argv) { @autoreleasepool {
  CHECK(argc==2); if(argc!=2)return 1;
  YLFMediaContextRef context=NULL;YLFMediaInfo info={0};
  CHECK(ylf_open_local(argv[1],&context,&info)==0);if(!context)return 1;
  int audio=-1;YLFStreamInfo stream;
  for(int i=0;i<info.stream_count;i++) { CHECK(ylf_copy_stream_info(context,i,&stream)==0);
    if(stream.kind==YLFStreamAudio) {audio=i;CHECK(stream.codec==YLFCodecOpus);} }
  CHECK(audio>=0);if(audio<0)return 1;
  CHECK(ylf_stream_opus_delay_samples(context,audio)==312);
  uint8_t head[19];CHECK(ylf_copy_stream_codec_config(context,audio,head,19)==0);
  YLFOpusDecoderRef decoder=ylf_opus_create(head,19);CHECK(decoder!=NULL);
  for(int pass=0;pass<2;pass++) {
    if(pass) {CHECK(ylf_seek(context,0)==0);ylf_opus_reset(decoder);}
    int frames=0,skipTotal=0,discardTotal=0,packets=0;YLFPacketRef packet=NULL;
    while(ylf_read_packet(context,&packet)==0) {
      if(ylf_packet_stream_index(packet)==audio) {
        uint32_t skip=0,discard=0;CHECK(ylf_packet_audio_trim(packet,&skip,&discard)==0);
        if(packets==0) {CHECK(skip==312);fprintf(stderr,"pass%d startPTS=%lld streamStart=%lld skip=%u\n",pass,(long long)ylf_packet_pts_us(packet),(long long)context->format->streams[audio]->start_time,skip);}
        float pcm[5760*2];int32_t count=0,offset=0;
        CHECK(ylf_opus_decode(decoder,ylf_packet_data(packet),ylf_packet_size(packet),skip,discard,pcm,5760,&count,&offset)==0);
        frames+=count;skipTotal+=offset;discardTotal+=discard;packets++;
      }
      ylf_packet_release(&packet);
    }
    CHECK(packets==201);CHECK(frames==192000);CHECK(skipTotal==312);CHECK(discardTotal==648);
  }
  for(int i=0;i<3;i++) {
    int64_t target=(int64_t[]){2000000,1250000,3000000}[i];
    CHECK(ylf_seek(context,target)==0);YLFPacketRef packet=NULL;bool seen=false;
    for(int n=0;n<100 && ylf_read_packet(context,&packet)==0;n++) {
      if(ylf_packet_stream_index(packet)==audio) {
        CHECK(ylf_packet_pts_us(packet)<=target-80000);uint32_t skip=99,discard=99;
        CHECK(ylf_packet_audio_trim(packet,&skip,&discard)==0);CHECK(skip==0);seen=true;
        // Corrupt side data must not be treated as missing trimming.
        av_packet_free_side_data(packet->value);av_packet_new_side_data(packet->value,AV_PKT_DATA_SKIP_SAMPLES,9);
        CHECK(ylf_packet_audio_trim(packet,&skip,&discard)!=0);
        ylf_packet_release(&packet);break;
      }ylf_packet_release(&packet);
    }CHECK(seen);
  }
  AVCodecParameters *par=context->format->streams[audio]->codecpar;
  par->seek_preroll=48000;CHECK(ylf_stream_opus_delay_samples(context,audio)<0);
  ylf_opus_free(decoder);ylf_close(&context);CHECK(ylf_debug_outstanding_packet_count()==0);
  fprintf(stderr,"Opus demux: %d checks, %d failures\n",checks,failures);return failures?1:0;
}}
