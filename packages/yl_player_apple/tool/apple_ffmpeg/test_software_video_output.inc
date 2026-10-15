static int checks,failures;
static NSData *reference;
static atomic_uint_least64_t chargedBytes;static atomic_uint_least32_t chargedFrames;
static int32_t reserve(void *context,uint64_t bytes,uint32_t frames,void **token){
 if(context){*token=NULL;return -1;}
 uint64_t *record=calloc(2,sizeof(uint64_t));if(!record)return -1;
 record[0]=bytes;record[1]=frames;chargedBytes+=bytes;chargedFrames+=frames;*token=record;return 0;
}
static void release(void *token){uint64_t *record=token;chargedBytes-=record[0];chargedFrames-=(uint32_t)record[1];free(record);}

#define CHECK(x) do {checks++; if(!(x)){failures++;fprintf(stderr,"FAIL %d %s\n",__LINE__,#x);}}while(0)
static CMSampleBufferRef sample(NSDictionary *row, CMVideoFormatDescriptionRef format) {
 NSData *data=[[NSData alloc]initWithBase64EncodedString:row[@"data"] options:0];
 CMBlockBufferRef block=NULL;CMSampleBufferRef result=NULL;
 CHECK(CMBlockBufferCreateWithMemoryBlock(NULL,NULL,data.length,NULL,NULL,0,data.length,0,&block)==0);
 CHECK(CMBlockBufferReplaceDataBytes(data.bytes,block,0,data.length)==0);
 CMSampleTimingInfo timing={CMTimeMake([row[@"durationUs"] longLongValue],1000000),
  CMTimeMake([row[@"ptsUs"] longLongValue],1000000),kCMTimeInvalid};size_t size=data.length;
 CHECK(CMSampleBufferCreateReady(NULL,block,format,1,1,&timing,1,&size,&result)==0);
 CFRelease(block);return result;
}
static int drain(YLFSoftwareVideoDecoderRef decoder, int depth, int *count, int64_t *previous, NSMutableArray *images) {
 for(;;){CVPixelBufferRef image=NULL;CMTime pts,duration;
  int result=ylf_software_video_receive(decoder,&image,&pts,&duration);
  if(result!=0){CHECK(image==NULL);return result;}
  CHECK(image!=NULL); if(!image)return -99;
  CHECK(CVPixelBufferGetWidth(image)==320 && CVPixelBufferGetHeight(image)==180);
  int64_t us=CMTimeConvertScale(pts,1000000,kCMTimeRoundingMethod_Default).value;
  CHECK(us>=*previous);*previous=us;CHECK(CMTIME_IS_NUMERIC(duration));
  OSType pixel=CVPixelBufferGetPixelFormatType(image);
  CHECK(pixel==(depth==10?kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));
  CHECK(CVPixelBufferLockBaseAddress(image,kCVPixelBufferLock_ReadOnly)==0);
  const uint8_t *luma=CVPixelBufferGetBaseAddressOfPlane(image,0);
  int y=depth==10?(*(const uint16_t *)luma)>>6:luma[0];
  // All source references start with an owned red marker (Y~81 in 8 bit).
  if(*count<24)CHECK(abs(y-(depth==10?324:81))<=4);
  size_t sampleBytes=depth==10?2:1, planeSize=320*180*sampleBytes;
  CHECK(reference.length>=(size_t)(*count+1)*planeSize*3/2);
  if(reference.length>=(size_t)(*count+1)*planeSize*3/2){
   const uint8_t *expected=(const uint8_t *)reference.bytes+(*count)*planeSize*3/2;
   int maximumDifference=0;
   for(int plane=0;plane<3;plane++)for(int row=0;row<(plane?90:180);row++)for(int col=0;col<(plane?160:320);col++){
    const uint8_t *actual=CVPixelBufferGetBaseAddressOfPlane(image,plane?1:0);
    size_t stride=CVPixelBufferGetBytesPerRowOfPlane(image,plane?1:0);
    size_t offset=plane?planeSize+(plane-1)*planeSize/4:0;
    int av=depth==10?((const uint16_t *)(actual+row*stride))[plane?col*2+plane-1:col]>>6:actual[row*stride+(plane?col*2+plane-1:col)];
    int ev=depth==10?((const uint16_t *)(expected+offset))[row*(plane?160:320)+col]:expected[offset+row*(plane?160:320)+col];
    maximumDifference=MAX(maximumDifference,abs(av-ev));
   }
   if(maximumDifference>1)fprintf(stderr,"frame=%d pts=%lld depth=%d Y=%d refY=%d maxDiff=%d\n",*count,(long long)us,depth,y,depth==10?*(const uint16_t *)expected:expected[0],maximumDifference);
   CHECK(maximumDifference<=1);
  }
  CVPixelBufferUnlockBaseAddress(image,kCVPixelBufferLock_ReadOnly);
  if(*count==0)[images addObject:(__bridge id)image];
  CFRelease(image);(*count)++;
 }
}
