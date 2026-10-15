#include <libavutil/imgutils.h>
#include <dav1d/dav1d.h>

// Ref-counted independently of decoder: references and published images may
// outlive reset/free. Internal codec bookkeeping is measured separately from
// these owned buffers; this is not a claim to cap total process RSS.
struct YLFSWBudget {
 pthread_mutex_t mutex;
 atomic_uint references;
 YLFSoftwareVideoLimits limits;
 uint64_t bytes;
 uint32_t frames;
 bool failed;
};
struct YLFSWAllocation {
 struct YLFSWBudget *budget;
 uint64_t bytes; uint32_t frames;
 void *external_token;
};
struct YLFSoftwareVideoDecoder {
 AVCodecContext *codec;
 struct YLFSWBudget *budget;
 AVFrame *frame;
 int width,height,depth;
 enum AVPixelFormat format;
 CFDictionaryRef hdr;
 int colors[4];
 bool colors_bound;
 bool finished,failed;
};
static void ylf_sw_budget_release(struct YLFSWBudget *b) {
 if(atomic_fetch_sub(&b->references,1)==1){pthread_mutex_destroy(&b->mutex);free(b);}
}
static struct YLFSWAllocation *ylf_sw_reserve(struct YLFSWBudget *b,uint64_t bytes,uint32_t frames) {
 pthread_mutex_lock(&b->mutex);
 bool valid=!b->failed && bytes>0 && bytes<=b->limits.max_owned_bytes-b->bytes &&
  frames<=b->limits.max_frames-b->frames;
 if(!valid){b->failed=true;pthread_mutex_unlock(&b->mutex);return NULL;}
 struct YLFSWAllocation *a=calloc(1,sizeof(*a));
 if(!a){b->failed=true;pthread_mutex_unlock(&b->mutex);return NULL;}
 if(b->limits.reserve && (b->limits.reserve(b->limits.account_context,bytes,frames,&a->external_token)!=0 || !a->external_token)){
  free(a);b->failed=true;pthread_mutex_unlock(&b->mutex);return NULL;
 }
 b->bytes+=bytes;b->frames+=frames;atomic_fetch_add(&b->references,1);
 a->budget=b;a->bytes=bytes;a->frames=frames;pthread_mutex_unlock(&b->mutex);return a;
}
static void ylf_sw_allocation_release(struct YLFSWAllocation *a) {
 struct YLFSWBudget *b=a->budget;
 pthread_mutex_lock(&b->mutex);b->bytes-=a->bytes;b->frames-=a->frames;pthread_mutex_unlock(&b->mutex);
 if(a->external_token)b->limits.release(a->external_token);
 free(a);ylf_sw_budget_release(b);
}
static void ylf_sw_free_buffer(void *opaque,uint8_t *data) {
 av_free(data);ylf_sw_allocation_release(opaque);
}
static int ylf_sw_get_buffer(AVCodecContext *codec,AVFrame *frame,int flags) {
 struct YLFSoftwareVideoDecoder *d=codec->opaque;
 if(frame->format!=d->format || frame->width<=0 || frame->height<=0 ||
  frame->width>FFALIGN(d->width,128) || frame->height>FFALIGN(d->height,128))return AVERROR(EINVAL);
 int w=frame->width,h=frame->height,align[AV_NUM_DATA_POINTERS]={0};
 avcodec_align_dimensions2(codec,&w,&h,align);
 int size=av_image_get_buffer_size(frame->format,w,h,64);
 if(size<=0 || size>INT_MAX-AV_INPUT_BUFFER_PADDING_SIZE)return AVERROR(EINVAL);
 size+=AV_INPUT_BUFFER_PADDING_SIZE;
 struct YLFSWAllocation *charge=ylf_sw_reserve(d->budget,(uint64_t)size,1);
 if(!charge)return AVERROR(ENOMEM);
 uint8_t *data=av_mallocz(size);
 if(!data){ylf_sw_allocation_release(charge);return AVERROR(ENOMEM);}
 frame->buf[0]=av_buffer_create(data,size,ylf_sw_free_buffer,charge,0);
 if(!frame->buf[0]){ylf_sw_free_buffer(charge,data);return AVERROR(ENOMEM);}
 if(av_image_fill_arrays(frame->data,frame->linesize,data,frame->format,w,h,64)<0){av_buffer_unref(&frame->buf[0]);return AVERROR(EINVAL);}
 frame->extended_data=frame->data;
 return 0;
}
static bool ylf_sw_av1_config(const uint8_t *data,size_t size,int width,int height,int *depth) {
 if(!data || size<=4 || size>1024*1024 || data[0]!=0x81 || (data[1]>>5)!=0 ||
   (data[2]&0x10) || (data[2]&0x0c)!=0x0c || (data[2]&3)==3 || (data[3]&0xe0) || (!(data[3]&0x10) && (data[3]&15)))return false;
 Dav1dSequenceHeader seq={0};
 if(dav1d_parse_sequence_header(&seq,data+4,size-4)<0 || seq.profile!=0 ||
  seq.layout!=DAV1D_PIXEL_LAYOUT_I420 || seq.hbd>1 || seq.max_width!=width || seq.max_height!=height)return false;
 *depth=seq.hbd?10:8;
 return ((data[2]&0x40)!=0)==(seq.hbd!=0) && !(data[2]&0x20);
}
static int32_t ylf_av1_format(const AVCodecParameters *parameters,
 const uint8_t *configuration,size_t size,CMVideoFormatDescriptionRef *out) {
 int depth=0;
 if(parameters->width<=0 || parameters->height<=0 || parameters->width>8192 || parameters->height>8192 ||
  ylf_video_side_data(parameters,AV_PKT_DATA_DOVI_CONF) ||
  !ylf_sw_av1_config(configuration,size,parameters->width,parameters->height,&depth))return YLFResultVideoConfigurationInvalid;
 Dav1dSequenceHeader seq={0};
 if(dav1d_parse_sequence_header(&seq,configuration+4,size-4)<0)return YLFResultVideoConfigurationInvalid;
 const int container[]={parameters->color_primaries,parameters->color_trc,parameters->color_space};
 const int bitstream[]={seq.pri,seq.trc,seq.mtrx};
 for(int i=0;i<3;i++)if(container[i]!=2 && bitstream[i]!=2 && container[i]!=bitstream[i])return YLFResultVideoConfigurationInvalid;
 if(parameters->color_range!=AVCOL_RANGE_UNSPECIFIED &&
  (parameters->color_range==AVCOL_RANGE_JPEG)!=(seq.color_range!=0))return YLFResultVideoConfigurationInvalid;
 NSMutableDictionary *ext=[NSMutableDictionary dictionary];
 ext[(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]=@{@"av1C":[NSData dataWithBytes:configuration length:size]};
 ext[(__bridge NSString *)kCMFormatDescriptionExtension_FullRangeVideo]=@(seq.color_range!=0);
 ylf_set_color(ext,kCMFormatDescriptionExtension_ColorPrimaries,ylf_color_primaries((enum AVColorPrimaries)seq.pri));
 ylf_set_color(ext,kCMFormatDescriptionExtension_TransferFunction,ylf_transfer_function((enum AVColorTransferCharacteristic)seq.trc));
 ylf_set_color(ext,kCMFormatDescriptionExtension_YCbCrMatrix,ylf_color_matrix((enum AVColorSpace)seq.mtrx));
 CMVideoFormatDescriptionRef base=NULL;
 OSStatus result=CMVideoFormatDescriptionCreate(NULL,kCMVideoCodecType_AV1,parameters->width,parameters->height,(__bridge CFDictionaryRef)ext,&base);
 if(result==0 && base)result=ylf_apply_video_metadata(parameters,base,out);
 if(base)CFRelease(base);
 return result==0 && *out?YLFResultOK:YLFResultVideoConfigurationInvalid;
}
int32_t ylf_software_video_create(YLFMediaContextRef context,int32_t stream,
 YLFSoftwareVideoLimits limits,YLFSoftwareVideoDecoderRef *out_decoder) {
 if(!out_decoder)return YLFResultInvalidArgument;*out_decoder=NULL;
 if(!context || !context->format || stream<0 || (unsigned)stream>=context->format->nb_streams ||
  !limits.max_owned_bytes || !limits.max_frames || !limits.max_packet_bytes || !limits.threads || limits.threads>16 ||
  limits.max_packet_bytes>limits.max_owned_bytes || (!!limits.reserve != !!limits.release))return YLFResultInvalidArgument;
 AVCodecParameters *p=context->format->streams[stream]->codecpar;
 if(p->codec_type!=AVMEDIA_TYPE_VIDEO || p->width<=0 || p->height<=0 || p->width>8192 || p->height>8192 ||
  ylf_video_side_data(p,AV_PKT_DATA_DOVI_CONF))return YLFResultVideoConfigurationInvalid;
 int depth=8;const AVCodec *implementation=NULL;
 if(p->codec_id==AV_CODEC_ID_AV1){
  if(!ylf_sw_av1_config(p->extradata,p->extradata_size,p->width,p->height,&depth))return YLFResultVideoConfigurationInvalid;
  implementation=avcodec_find_decoder_by_name("libdav1d");
 }else if(p->codec_id==AV_CODEC_ID_VP9 && (p->profile==0 || p->profile==2)){
  // Profile 0 normatively fixes 8-bit 4:2:0. Demux-only discovery need not
  // instantiate a decoder just to populate pix_fmt. Profile 2 needs measured
  // explicit 10-bit format evidence; unknown/12-bit remains rejected.
  if(p->profile==0 && (p->format==AV_PIX_FMT_NONE || p->format==AV_PIX_FMT_YUV420P))depth=8;
  else if(p->profile==2 && p->format==AV_PIX_FMT_YUV420P10LE)depth=10;
  else return YLFResultVideoConfigurationInvalid;
  implementation=avcodec_find_decoder_by_name("vp9");
 }else return YLFResultVideoConfigurationInvalid;
 if(!implementation)return YLFResultVideoConfigurationInvalid;
 if(p->extradata_size<0 || p->extradata_size>1024*1024)return YLFResultVideoConfigurationInvalid;
 CMVideoFormatDescriptionRef validated=NULL;
 if(p->codec_id==AV_CODEC_ID_AV1){
  int validation=ylf_av1_format(p,p->extradata,p->extradata_size,&validated);
  if(validated)CFRelease(validated);
  if(validation!=0)return validation;
 }
 NSMutableDictionary *hdr=[NSMutableDictionary dictionary],*atoms=[NSMutableDictionary dictionary];
 if(!ylf_apply_static_hdr(p,hdr,atoms))return YLFResultVideoConfigurationInvalid;
 struct YLFSoftwareVideoDecoder *d=calloc(1,sizeof(*d));if(!d)return YLFResultResourceExhausted;
 d->budget=calloc(1,sizeof(*d->budget));if(!d->budget){free(d);return YLFResultResourceExhausted;}
 pthread_mutex_init(&d->budget->mutex,NULL);atomic_init(&d->budget->references,1);d->budget->limits=limits;
 d->hdr=CFBridgingRetain([hdr copy]);
 d->colors[0]=p->color_primaries;d->colors[1]=p->color_trc;d->colors[2]=p->color_space;d->colors[3]=p->color_range;
 if(p->codec_id==AV_CODEC_ID_AV1){
  Dav1dSequenceHeader seq={0};dav1d_parse_sequence_header(&seq,p->extradata+4,p->extradata_size-4);
  if(d->colors[0]==2)d->colors[0]=seq.pri;if(d->colors[1]==2)d->colors[1]=seq.trc;if(d->colors[2]==2)d->colors[2]=seq.mtrx;
  if(d->colors[3]==AVCOL_RANGE_UNSPECIFIED)d->colors[3]=seq.color_range?AVCOL_RANGE_JPEG:AVCOL_RANGE_MPEG;
 }
 d->width=p->width;d->height=p->height;d->depth=depth;d->format=depth==10?AV_PIX_FMT_YUV420P10LE:AV_PIX_FMT_YUV420P;
 d->codec=avcodec_alloc_context3(implementation);d->frame=av_frame_alloc();
 if(!d->codec || !d->frame || avcodec_parameters_to_context(d->codec,p)<0){ylf_software_video_free(d);return YLFResultResourceExhausted;}
 d->codec->opaque=d;d->codec->get_buffer2=ylf_sw_get_buffer;d->codec->thread_count=limits.threads;
 d->codec->thread_type=FF_THREAD_SLICE;d->codec->max_pixels=(int64_t)p->width*p->height;
 d->codec->pkt_timebase=(AVRational){1,1000000};d->codec->err_recognition=AV_EF_EXPLODE;
 if(p->codec_id==AV_CODEC_ID_AV1)av_opt_set_int(d->codec->priv_data,"max_frame_delay",1,0);
 if(avcodec_open2(d->codec,implementation,NULL)<0){ylf_software_video_free(d);return YLFResultVideoConfigurationInvalid;}
 *out_decoder=d;return YLFResultOK;
}
static int32_t ylf_sw_result(struct YLFSoftwareVideoDecoder *d,int result) {
 pthread_mutex_lock(&d->budget->mutex);bool failed=d->budget->failed;pthread_mutex_unlock(&d->budget->mutex);
 if(failed){d->failed=true;return YLFResultResourceExhausted;}
 if(result>=0)return YLFResultOK;
 if(result==AVERROR(EAGAIN))return YLFResultWouldBlock;
 if(result==AVERROR_EOF)return YLFResultEOF;
 d->failed=true;
 return result==AVERROR(ENOMEM)?YLFResultResourceExhausted:YLFResultVideoConfigurationInvalid;
}
int32_t ylf_software_video_send(YLFSoftwareVideoDecoderRef d,CMSampleBufferRef sample) {
 if(!d || !sample || d->failed || d->finished)return YLFResultInvalidArgument;
 CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);size_t size=block?CMBlockBufferGetDataLength(block):0;
 if(!size || size>d->budget->limits.max_packet_bytes || size>INT_MAX-AV_INPUT_BUFFER_PADDING_SIZE){d->failed=true;return YLFResultResourceExhausted;}
 struct YLFSWAllocation *charge=ylf_sw_reserve(d->budget,size+AV_INPUT_BUFFER_PADDING_SIZE,0);
 if(!charge){d->failed=true;return YLFResultResourceExhausted;}
 uint8_t *data=av_mallocz(size+AV_INPUT_BUFFER_PADDING_SIZE);AVPacket *packet=av_packet_alloc();
 if(!data || !packet){av_free(data);av_packet_free(&packet);ylf_sw_allocation_release(charge);d->failed=true;return YLFResultResourceExhausted;}
 packet->buf=av_buffer_create(data,size+AV_INPUT_BUFFER_PADDING_SIZE,ylf_sw_free_buffer,charge,0);
 if(!packet->buf){ylf_sw_free_buffer(charge,data);av_packet_free(&packet);d->failed=true;return YLFResultResourceExhausted;}
 packet->data=data;packet->size=(int)size;
 CMTime pts=CMSampleBufferGetPresentationTimeStamp(sample),duration=CMSampleBufferGetDuration(sample);
 if(!CMTIME_IS_NUMERIC(pts) || !CMTIME_IS_NUMERIC(duration) || CMTimeCompare(duration,kCMTimeZero)<0 ||
  CMBlockBufferCopyDataBytes(block,0,size,data)!=0){av_packet_free(&packet);d->failed=true;return YLFResultInvalidArgument;}
 packet->pts=CMTimeConvertScale(pts,1000000,kCMTimeRoundingMethod_Default).value;
 packet->dts=packet->pts;packet->duration=CMTimeConvertScale(duration,1000000,kCMTimeRoundingMethod_Default).value;
 int result=avcodec_send_packet(d->codec,packet);av_packet_free(&packet);return ylf_sw_result(d,result);
}
static void ylf_sw_pixel_release(void *opaque,const void *data,size_t size,size_t planes,const void *addresses[]) {
 av_free((void *)data);ylf_sw_allocation_release(opaque);
}
int32_t ylf_software_video_receive(YLFSoftwareVideoDecoderRef d,CVPixelBufferRef *image,CMTime *pts,CMTime *duration) {
 if(image)*image=NULL;if(pts)*pts=kCMTimeInvalid;if(duration)*duration=kCMTimeInvalid;
 if(!d || !image || !pts || !duration || d->failed)return YLFResultInvalidArgument;
 int result=avcodec_receive_frame(d->codec,d->frame);if(result<0)return ylf_sw_result(d,result);
 AVFrame *f=d->frame;
 if(f->width!=d->width || f->height!=d->height || f->format!=d->format || f->pts==AV_NOPTS_VALUE){
  av_frame_unref(f);d->failed=true;return YLFResultVideoConfigurationInvalid;
 }
 int colors[]={f->color_primaries,f->color_trc,f->colorspace,f->color_range};
 for(int i=0;i<4;i++){
  int unknown=i==3?AVCOL_RANGE_UNSPECIFIED:2;
  if(colors[i]==unknown)colors[i]=d->colors[i];
  if(d->colors[i]!=unknown && colors[i]!=unknown && colors[i]!=d->colors[i]){
   av_frame_unref(f);d->failed=true;return YLFResultVideoConfigurationInvalid;
  }
 }
 if(!d->colors_bound){memcpy(d->colors,colors,sizeof(colors));d->colors_bound=true;}
 // Any in-band static HDR must match the admitted container descriptor. New or
 // changed metadata requires reconfiguration rather than silent attachment loss.
 AVPacketSideData sides[2]={0};AVCodecParameters metadata={0};
 const enum AVFrameSideDataType types[]={AV_FRAME_DATA_MASTERING_DISPLAY_METADATA,AV_FRAME_DATA_CONTENT_LIGHT_LEVEL};
 const enum AVPacketSideDataType packets[]={AV_PKT_DATA_MASTERING_DISPLAY_METADATA,AV_PKT_DATA_CONTENT_LIGHT_LEVEL};
 for(int i=0;i<2;i++){
  AVFrameSideData *side=av_frame_get_side_data(f,types[i]);
  if(side){sides[metadata.nb_coded_side_data++]=(AVPacketSideData){.data=side->data,.size=side->size,.type=packets[i]};}
 }
 metadata.coded_side_data=sides;
 NSMutableDictionary *frameHDR=[NSMutableDictionary dictionary],*frameAtoms=[NSMutableDictionary dictionary];
 if(!ylf_apply_static_hdr(&metadata,frameHDR,frameAtoms)){av_frame_unref(f);d->failed=true;return YLFResultVideoConfigurationInvalid;}
 NSDictionary *admittedHDR=(__bridge NSDictionary *)d->hdr;
 for(NSString *key in frameHDR)if(![frameHDR[key] isEqual:admittedHDR[key]]){
  av_frame_unref(f);d->failed=true;return YLFResultVideoConfigurationInvalid;
 }
 const size_t bytes=d->depth==10?2:1,w=d->width,h=d->height,cw=(w+1)/2,ch=(h+1)/2;
 size_t ystride=FFALIGN(w*bytes,64),uvstride=FFALIGN(cw*2*bytes,64),size=ystride*h+uvstride*ch;
 struct YLFSWAllocation *charge=ylf_sw_reserve(d->budget,size,1);
 uint8_t *data=charge?av_mallocz(size):NULL;
 if(!data){if(charge)ylf_sw_allocation_release(charge);av_frame_unref(f);d->failed=true;return YLFResultResourceExhausted;}
 for(size_t row=0;row<h;row++){
  if(bytes==1)memcpy(data+row*ystride,f->data[0]+row*f->linesize[0],w);
  else for(size_t col=0;col<w;col++)((uint16_t *)(data+row*ystride))[col]=((uint16_t *)(f->data[0]+row*f->linesize[0]))[col]<<6;
 }
 for(size_t row=0;row<ch;row++)for(size_t col=0;col<cw;col++){
  if(bytes==1){data[ystride*h+row*uvstride+col*2]=f->data[1][row*f->linesize[1]+col];data[ystride*h+row*uvstride+col*2+1]=f->data[2][row*f->linesize[2]+col];}
  else {uint16_t *uv=(uint16_t *)(data+ystride*h+row*uvstride);uv[col*2]=((uint16_t *)(f->data[1]+row*f->linesize[1]))[col]<<6;uv[col*2+1]=((uint16_t *)(f->data[2]+row*f->linesize[2]))[col]<<6;}
 }
 void *planes[]={data,data+ystride*h};size_t widths[]={w,cw},heights[]={h,ch},strides[]={ystride,uvstride};
 bool full=colors[3]==AVCOL_RANGE_JPEG;
 OSType type=bytes==2?(full?kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange):(full?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
 CVReturn status=CVPixelBufferCreateWithPlanarBytes(NULL,w,h,type,data,size,2,planes,widths,heights,strides,ylf_sw_pixel_release,charge,NULL,image);
 if(status!=kCVReturnSuccess){ylf_sw_pixel_release(charge,data,size,0,NULL);av_frame_unref(f);d->failed=true;return YLFResultResourceExhausted;}
 CFStringRef prim=ylf_color_primaries((enum AVColorPrimaries)colors[0]),transfer=ylf_transfer_function((enum AVColorTransferCharacteristic)colors[1]),matrix=ylf_color_matrix((enum AVColorSpace)colors[2]);
 if(prim)CVBufferSetAttachment(*image,kCVImageBufferColorPrimariesKey,prim,kCVAttachmentMode_ShouldPropagate);
 if(transfer)CVBufferSetAttachment(*image,kCVImageBufferTransferFunctionKey,transfer,kCVAttachmentMode_ShouldPropagate);
 if(matrix)CVBufferSetAttachment(*image,kCVImageBufferYCbCrMatrixKey,matrix,kCVAttachmentMode_ShouldPropagate);
 for(NSString *key in admittedHDR)CVBufferSetAttachment(*image,(__bridge CFStringRef)key,(__bridge CFTypeRef)admittedHDR[key],kCVAttachmentMode_ShouldPropagate);
 *pts=CMTimeMake(f->pts,1000000);*duration=CMTimeMake(f->duration,1000000);av_frame_unref(f);return YLFResultOK;
}
int32_t ylf_software_video_finish(YLFSoftwareVideoDecoderRef d){
 if(!d || d->failed)return YLFResultInvalidArgument;
 if(d->finished)return YLFResultOK;
 int result=avcodec_send_packet(d->codec,NULL);if(result==0 || result==AVERROR_EOF)d->finished=true;
 return result==AVERROR_EOF?YLFResultOK:ylf_sw_result(d,result);
}
void ylf_software_video_reset(YLFSoftwareVideoDecoderRef d){
 if(!d || d->failed)return;
 avcodec_flush_buffers(d->codec);av_frame_unref(d->frame);d->finished=false;
}
void ylf_software_video_free(YLFSoftwareVideoDecoderRef d){
 if(!d)return;if(d->hdr)CFRelease(d->hdr);avcodec_free_context(&d->codec);av_frame_free(&d->frame);ylf_sw_budget_release(d->budget);free(d);
}

struct YLFSoftwareVideoConfiguration { AVFormatContext *format; };
int32_t ylf_software_video_copy_configuration(YLFMediaContextRef context,int32_t stream,YLFSoftwareVideoConfigurationRef *out) {
 if(!out)return YLFResultInvalidArgument;*out=NULL;
 if(!context || !context->format || stream<0 || (unsigned)stream>=context->format->nb_streams)return YLFResultInvalidArgument;
 AVCodecParameters *p=context->format->streams[stream]->codecpar;
 if(p->codec_type!=AVMEDIA_TYPE_VIDEO || (p->codec_id!=AV_CODEC_ID_AV1 && p->codec_id!=AV_CODEC_ID_VP9) ||
  p->width<=0 || p->height<=0 || p->width>8192 || p->height>8192 || p->extradata_size<0 || p->extradata_size>1024*1024 ||
  (p->extradata_size>0 && !p->extradata) || p->nb_coded_side_data<0 || p->nb_coded_side_data>64)return YLFResultVideoConfigurationInvalid;
 size_t metadataBytes=0;
 for(int i=0;i<p->nb_coded_side_data;i++){
  if(p->coded_side_data[i].size>65536-metadataBytes)return YLFResultVideoConfigurationInvalid;
  metadataBytes+=p->coded_side_data[i].size;
 }
 struct YLFSoftwareVideoConfiguration *copy=calloc(1,sizeof(*copy));
 if(!copy)return YLFResultResourceExhausted;
 copy->format=avformat_alloc_context();
 AVStream *target=copy->format?avformat_new_stream(copy->format,NULL):NULL;
 if(!target || avcodec_parameters_copy(target->codecpar,p)<0){ylf_software_video_free_configuration(copy);return YLFResultResourceExhausted;}
 *out=copy;return YLFResultOK;
}
void ylf_software_video_free_configuration(YLFSoftwareVideoConfigurationRef config) {
 if(!config)return;avformat_free_context(config->format);free(config);
}
int32_t ylf_software_video_create_from_configuration(YLFSoftwareVideoConfigurationRef config,YLFSoftwareVideoLimits limits,YLFSoftwareVideoDecoderRef *out) {
 if(out)*out=NULL;if(!config)return YLFResultInvalidArgument;
 struct YLFMediaContext view={0};view.format=config->format;
 return ylf_software_video_create(&view,0,limits,out);
}
