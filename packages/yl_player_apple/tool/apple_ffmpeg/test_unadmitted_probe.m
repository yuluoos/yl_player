#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
#include <libavformat/internal.h>
int main(int argc,char **argv){@autoreleasepool{
 if(argc!=2)return 2;YLFMediaContextRef context=NULL;YLFMediaInfo info={0};
 if(ylf_open_local(argv[1],&context,&info)!=0)return 3;
 int failures=0,video=0;
 for(unsigned i=0;i<context->format->nb_streams;i++){
  AVStream *stream=context->format->streams[i];
  if(stream->codecpar->codec_type!=AVMEDIA_TYPE_VIDEO)continue;
  video++;
  // Exercise FFmpeg's exact probe whitelist option with a real cloned stream.
  // Metadata-complete fixtures may not need decoding during find_stream_info;
  // incomplete metadata must still be unable to open this unadmitted decoder.
  const AVCodec *implementation=avcodec_find_decoder(stream->codecpar->codec_id);
  AVCodecContext *probe=avcodec_alloc_context3(implementation);
  avcodec_parameters_to_context(probe,stream->codecpar);probe->thread_count=1;
  AVDictionary *options=NULL;
  if(context->format->codec_whitelist)av_dict_set(&options,"codec_whitelist",context->format->codec_whitelist,0);
  if(avcodec_open2(probe,implementation,&options)>=0){fprintf(stderr,"FAIL: probe policy permits unadmitted video decoder\n");failures++;}
  av_dict_free(&options);avcodec_free_context(&probe);
  AVCodecContext *decoder=ffstream(stream)->avctx;
  if(decoder && avcodec_is_open(decoder)){fprintf(stderr,"FAIL: discovery opened unadmitted video decoder %s\n",decoder->codec->name);failures++;}
 }
 ylf_close(&context);printf("Unadmitted probe: videos=%d failures=%d\n",video,failures);return !video||failures?1:0;
}}
