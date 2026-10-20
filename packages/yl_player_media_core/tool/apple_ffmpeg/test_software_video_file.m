#ifdef YL_SOFTWARE_ARTIFACT
#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <YlFFmpegBridge/YlFFmpegBridge.h>
#else
#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
#endif
#include "test_software_video_output.inc"
int main(int argc,char **argv){@autoreleasepool{
 CHECK(argc==4);if(argc!=4)return 2;
 NSDictionary *fixture=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:NULL];
 reference=[NSData dataWithContentsOfFile:@(argv[3])];CHECK(fixture && reference);
 YLFMediaContextRef context=NULL;YLFMediaInfo info={0};
 CHECK(ylf_open_local(argv[2],&context,&info)==0);if(!context)return 1;
 int video=-1;
 for(int i=0;i<info.stream_count;i++){YLFStreamInfo stream={0};CHECK(ylf_copy_stream_info(context,i,&stream)==0);if(stream.codec==YLFCodecAV1 || stream.codec==YLFCodecVP9)video=i;}
 CHECK(video>=0);
 YLFSoftwareVideoLimits limits={32*1024*1024,64,1024*1024,2,NULL,reserve,release};
 YLFSoftwareVideoDecoderRef decoder=NULL;
 YLFSoftwareVideoConfigurationRef configuration=NULL;
 CHECK(ylf_software_video_copy_configuration(context,video,&configuration)==0);CHECK(configuration!=NULL);
 YLFSoftwareVideoDescriptor descriptor={0};
 CHECK(ylf_software_video_copy_descriptor(configuration,sizeof(descriptor),&descriptor)==0);
 CHECK(descriptor.width==320 && descriptor.height==180);
 CHECK(descriptor.bit_depth==[fixture[@"bitDepth"]intValue]);
 CHECK(descriptor.fps_num==24 && descriptor.fps_den==1);
 CHECK(ylf_software_video_copy_descriptor(configuration,sizeof(descriptor)-1,&descriptor)!=0);
 ylf_close(&context);
 CHECK(ylf_software_video_create_from_configuration(configuration,limits,&decoder)==0);CHECK(decoder!=NULL);
 ylf_software_video_free_configuration(configuration);if(!decoder)return 1;
 CMVideoFormatDescriptionRef format=NULL;CHECK(CMVideoFormatDescriptionCreate(NULL,[fixture[@"codec"]isEqual:@"av1"]?'av01':'vp09',320,180,NULL,&format)==0);
 int count=0;int64_t previous=-1;NSMutableArray *images=[NSMutableArray array];
 for(NSDictionary *row in fixture[@"frames"]){CMSampleBufferRef s=sample(row,format);int result=ylf_software_video_send(decoder,s);
  if(result==YLFResultWouldBlock){CHECK(drain(decoder,[fixture[@"bitDepth"]intValue],&count,&previous,images)==YLFResultWouldBlock);result=ylf_software_video_send(decoder,s);}
  CHECK(result==0);CFRelease(s);CHECK(drain(decoder,[fixture[@"bitDepth"]intValue],&count,&previous,images)==YLFResultWouldBlock);
 }
 CHECK(ylf_software_video_finish(decoder)==0);CHECK(drain(decoder,[fixture[@"bitDepth"]intValue],&count,&previous,images)==YLFResultEOF);
 CHECK(count==[fixture[@"frames"]count]);ylf_software_video_free(decoder);CFRelease(format);
 CHECK(chargedBytes>0 && chargedFrames==1);[images removeAllObjects];CHECK(chargedBytes==0 && chargedFrames==0);
 printf("Software video file: %d checks, %d failures\n",checks,failures);return failures?1:0;
}}
