#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
#include "test_software_video_output.inc"
int main(int argc,char **argv){@autoreleasepool{
 CHECK(argc==3);if(argc!=3)return 1;
 reference=[NSData dataWithContentsOfFile:@(argv[2])];CHECK(reference!=nil);
 NSDictionary *fixture=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:NULL];CHECK(fixture!=nil);
 struct YLFMediaContext context={0};context.format=avformat_alloc_context();
 AVStream *stream=avformat_new_stream(context.format,NULL);AVCodecParameters *p=stream->codecpar;
 p->codec_type=AVMEDIA_TYPE_VIDEO;p->codec_id=[fixture[@"codec"] isEqual:@"av1"]?AV_CODEC_ID_AV1:AV_CODEC_ID_VP9;
 p->width=320;p->height=180;p->profile=0;p->format=[fixture[@"bitDepth"]intValue]==10?AV_PIX_FMT_YUV420P10LE:AV_PIX_FMT_YUV420P;
 NSData *config=[[NSData alloc]initWithBase64EncodedString:fixture[@"configuration"] options:0];
 p->extradata=av_mallocz(config.length+AV_INPUT_BUFFER_PADDING_SIZE);memcpy(p->extradata,config.bytes,config.length);p->extradata_size=(int)config.length;
 if(p->codec_id==AV_CODEC_ID_AV1){
 CMVideoFormatDescriptionRef av1Format=NULL;
 CHECK(ylf_codec(AV_CODEC_ID_AV1)==YLFCodecAV1);
 CHECK(ylf_copy_video_format_description(&context,0,&av1Format)==0);
 CHECK(av1Format!=NULL);if(av1Format)CFRelease(av1Format);
 for(int offset=0;offset<4;offset++){
  uint8_t original=p->extradata[offset];p->extradata[offset]=0xff;av1Format=NULL;
  CHECK(ylf_copy_video_format_description(&context,0,&av1Format)!=0);CHECK(av1Format==NULL);p->extradata[offset]=original;
 }
}
 YLFSoftwareVideoLimits limits={32*1024*1024,64,1024*1024,2,NULL,reserve,release};YLFSoftwareVideoDecoderRef decoder=NULL;
 CHECK(ylf_software_video_create(&context,0,limits,&decoder)==0);CHECK(decoder!=NULL);
 if(!decoder){avformat_close_input(&context.format);printf("Software video: %d checks, %d failures\n",checks,failures);return 1;}
 YLFSoftwareVideoDecoderRef invalid=(void *)1;
 int originalWidth=p->width;p->width=INT_MAX;
 CHECK(ylf_software_video_create(&context,0,limits,&invalid)!=0);CHECK(invalid==NULL);p->width=originalWidth;
 YLFSoftwareVideoLimits invalidLimits=limits;invalidLimits.threads=0;
 CHECK(ylf_software_video_create(&context,0,invalidLimits,&invalid)!=0);CHECK(invalid==NULL);
 CMVideoFormatDescriptionRef testingFormat=NULL;
 CHECK(CMVideoFormatDescriptionCreate(NULL,p->codec_id==AV_CODEC_ID_AV1?'av01':'vp09',320,180,NULL,&testingFormat)==0);
 CMSampleBufferRef testingSample=sample(fixture[@"frames"][0],testingFormat);
 for(int failure=0;failure<3;failure++){
  YLFSoftwareVideoLimits small=limits;
  if(failure==0){small.max_owned_bytes=1024;small.max_packet_bytes=512;}
  if(failure==1)small.max_packet_bytes=1;
  if(failure==2)small.account_context=(void *)1;
  YLFSoftwareVideoDecoderRef candidate=NULL;
  CHECK(ylf_software_video_create(&context,0,small,&candidate)==0);
  if(candidate){int r=ylf_software_video_send(candidate,testingSample);
   if(r==0){CVPixelBufferRef output=NULL;CMTime t,u;r=ylf_software_video_receive(candidate,&output,&t,&u);if(output)CFRelease(output);}
   CHECK(r==YLFResultResourceExhausted);
   CHECK(ylf_software_video_send(candidate,testingSample)!=0);
   ylf_software_video_free(candidate);
  }
 }
 CFRelease(testingSample);CFRelease(testingFormat);
 // Configuration ownership must survive closing its original demux context.
 avformat_close_input(&context.format);
 CMVideoFormatDescriptionRef format=NULL;
 CHECK(CMVideoFormatDescriptionCreate(NULL,[fixture[@"codec"] isEqual:@"av1"]?'av01':'vp09',320,180,NULL,&format)==0);
 int count=0;int64_t previous=-1;NSMutableArray *images=[NSMutableArray array];
 for(NSDictionary *row in fixture[@"frames"]){CMSampleBufferRef s=sample(row,format);
  int result=ylf_software_video_send(decoder,s);
  if(result==YLFResultWouldBlock){CHECK(drain(decoder,[fixture[@"bitDepth"]intValue],&count,&previous,images)==YLFResultWouldBlock);result=ylf_software_video_send(decoder,s);}
  CHECK(result==0);CFRelease(s);
  CHECK(drain(decoder,[fixture[@"bitDepth"]intValue],&count,&previous,images)==YLFResultWouldBlock);
 }
 CHECK(ylf_software_video_finish(decoder)==0);
 CHECK(drain(decoder,[fixture[@"bitDepth"]intValue],&count,&previous,images)==YLFResultEOF);
 CHECK(count==[fixture[@"frames"]count]);
 ylf_software_video_reset(decoder);
 CMSampleBufferRef first=sample(fixture[@"frames"][0],format);CHECK(ylf_software_video_send(decoder,first)==0);CFRelease(first);
 ylf_software_video_free(decoder);CFRelease(format);
 for(id value in images){CVPixelBufferRef image=(__bridge CVPixelBufferRef)value;CHECK(CVPixelBufferLockBaseAddress(image,kCVPixelBufferLock_ReadOnly)==0);CHECK(CVPixelBufferGetBaseAddressOfPlane(image,0)!=NULL);CVPixelBufferUnlockBaseAddress(image,kCVPixelBufferLock_ReadOnly);}
 CHECK(chargedBytes>0 && chargedFrames==1);
 [images removeAllObjects];CHECK(chargedBytes==0 && chargedFrames==0);
 printf("Software video: %d checks, %d failures\n",checks,failures);return failures?1:0;
}}
