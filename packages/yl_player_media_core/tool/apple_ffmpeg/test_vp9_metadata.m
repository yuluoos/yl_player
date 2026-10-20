#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
static int checks, failures;
#define CHECK(x) do { checks++; if(!(x)){ failures++; fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); } } while(0)
int main(){ @autoreleasepool {
 struct YLFMediaContext c={0}; c.format=avformat_alloc_context();
 AVStream *s=avformat_new_stream(c.format,NULL); AVCodecParameters *p=s->codecpar;
 p->codec_type=AVMEDIA_TYPE_VIDEO;p->codec_id=AV_CODEC_ID_VP9;p->width=320;p->height=180;
 uint8_t config[]={1,0,0,0,0,0,0x82,2,2,2,0,0};
 CMVideoFormatDescriptionRef f=NULL;
 CHECK(ylf_codec(AV_CODEC_ID_VP9)==11);
 CHECK(ylf_copy_video_format_description_with_codec_config(&c,0,config,12,&f)==0);
 if(f){CHECK(CMFormatDescriptionGetMediaSubType(f)==kCMVideoCodecType_VP9);CHECK(CMVideoFormatDescriptionGetDimensions(f).width==320);CFRelease(f);}
 for(int i=0;i<12;i++){f=NULL;CHECK(ylf_copy_video_format_description_with_codec_config(&c,0,config,i,&f)!=0);CHECK(f==NULL);}
 int offsets[]={0,1,4,6,7,8,9,10,11};int bad[]={0,1,2,0xa2,9,16,9,1,1};
 for(int i=0;i<9;i++){uint8_t old=config[offsets[i]];config[offsets[i]]=bad[i];f=NULL;CHECK(ylf_copy_video_format_description_with_codec_config(&c,0,config,12,&f)!=0);CHECK(f==NULL);config[offsets[i]]=old;}
 p->color_trc=AVCOL_TRC_SMPTE2084;CHECK(ylf_copy_video_format_description_with_codec_config(&c,0,config,12,&f)!=0);p->color_trc=AVCOL_TRC_UNSPECIFIED;
 p->width=65536;CHECK(ylf_copy_video_format_description_with_codec_config(&c,0,config,12,&f)!=0);
 avformat_close_input(&c.format);printf("VP9 metadata: %d checks, %d failures\n",checks,failures);return failures?1:0;
}}
