// Internal ABI is compiled only against the signed, pinned FFmpeg source tree.
#include "libavcodec/dovi_rpu.h"

struct YLFFELContext {
  DOVIContext dovi;
  AVDOVIDecoderConfigurationRecord config;
  int streamIndex, lengthSize;
  CMVideoFormatDescriptionRef base, enhancement;
  CFDataRef enhancementPS[3];
};

static const AVCodecParameters *ylf_fel_parameters(YLFMediaContextRef c, int i) {
  return c && c->format && i >= 0 && i < c->format->nb_streams ? c->format->streams[i]->codecpar : NULL;
}
int32_t ylf_stream_dolby_vision_profile(YLFMediaContextRef c, int32_t i) {
  const AVCodecParameters *p = ylf_fel_parameters(c, i);
  const AVPacketSideData *s = p ? ylf_video_side_data(p, AV_PKT_DATA_DOVI_CONF) : NULL;
  return s && s->size >= sizeof(AVDOVIDecoderConfigurationRecord) ? ((AVDOVIDecoderConfigurationRecord *)s->data)->dv_profile : 0;
}
static bool ylf_fel_valid(const AVCodecParameters *p, AVDOVIDecoderConfigurationRecord *cfg) {
  const AVPacketSideData *s = p ? ylf_video_side_data(p, AV_PKT_DATA_DOVI_CONF) : NULL;
  if (!s || !s->data || s->size < sizeof(*cfg)) return false;
  memcpy(cfg,s->data,sizeof(*cfg));
  return p->codec_id == AV_CODEC_ID_HEVC && cfg->dv_profile == 7 && cfg->dv_version_major == 1 &&
    cfg->dv_version_minor == 0 && cfg->dv_level >= 1 && cfg->dv_level <= 13 &&
    cfg->rpu_present_flag == 1 && cfg->el_present_flag == 1 && cfg->bl_present_flag == 1 &&
    cfg->dv_bl_signal_compatibility_id == 6 && cfg->dv_md_compression == 0 &&
    p->extradata_size >= 23 && p->extradata[0] == 1 && (p->extradata[16]&3)==1 &&
    (p->extradata[17]&7)==2 && (p->extradata[18]&7)==2;
}
int32_t ylf_fel_copy_base_format(YLFMediaContextRef c, int32_t i, CMVideoFormatDescriptionRef *out) {
  if (!out) return YLFResultInvalidArgument; *out = NULL;
  AVDOVIDecoderConfigurationRecord cfg;
  const AVCodecParameters *p = ylf_fel_parameters(c,i);
  if (!ylf_fel_valid(p,&cfg)) return YLFResultDolbyVisionUnsupported;
  NSMutableData *config = [NSMutableData dataWithBytes:p->extradata length:p->extradata_size];
  ((uint8_t *)config.mutableBytes)[21] |= 3; // Output always uses four-byte lengths.
  CMVideoFormatDescriptionRef raw = NULL;
  if (ylf_hevc_format_description(config.bytes,config.length,&raw)) return YLFResultVideoConfigurationInvalid;
  AVCodecParameters copy = *p;
  copy.coded_side_data = NULL; copy.nb_coded_side_data = 0;
  copy.color_primaries=AVCOL_PRI_BT2020; copy.color_trc=AVCOL_TRC_SMPTE2084;
  copy.color_space=AVCOL_SPC_BT2020_NCL; copy.color_range=AVCOL_RANGE_MPEG;
  OSStatus status=ylf_apply_video_metadata(&copy,raw,out); CFRelease(raw);
  return status ? YLFResultVideoConfigurationInvalid : 0;
}
int32_t ylf_fel_create(YLFMediaContextRef c, int32_t i, YLFFELContextRef *out) {
  if (!out) return YLFResultInvalidArgument; *out=NULL;
  AVDOVIDecoderConfigurationRecord cfg; const AVCodecParameters *p=ylf_fel_parameters(c,i);
  if (!ylf_fel_valid(p,&cfg)) return YLFResultDolbyVisionUnsupported;
  struct YLFFELContext *f=calloc(1,sizeof(*f)); if (!f) return YLFResultReadFailed;
  int ret=ylf_fel_copy_base_format(c,i,&f->base); if(ret){free(f);return ret;}
  f->config=f->dovi.cfg=cfg; f->streamIndex=i; f->lengthSize=(p->extradata[21]&3)+1; *out=f; return 0;
}
int32_t ylf_fel_clone(YLFFELContextRef f, YLFFELContextRef *out) {
  if(!out) return YLFResultInvalidArgument; *out=NULL; if(!f)return YLFResultInvalidArgument;
  struct YLFFELContext *n=calloc(1,sizeof(*n)); if(!n)return YLFResultReadFailed;
  n->config=n->dovi.cfg=f->config; n->streamIndex=f->streamIndex; n->lengthSize=f->lengthSize;
  n->base=(CMVideoFormatDescriptionRef)CFRetain(f->base);
  if(f->enhancement)n->enhancement=(CMVideoFormatDescriptionRef)CFRetain(f->enhancement);
  for(int i=0;i<3;i++)if(f->enhancementPS[i])n->enhancementPS[i]=(CFDataRef)CFRetain(f->enhancementPS[i]);
  *out=n;return 0;
}
void ylf_fel_reset(YLFFELContextRef f) {
  if(!f)return; ff_dovi_ctx_unref(&f->dovi); f->dovi.cfg=f->config;
  if(f->enhancement){CFRelease(f->enhancement);f->enhancement=NULL;}
  for(int i=0;i<3;i++)if(f->enhancementPS[i]){CFRelease(f->enhancementPS[i]);f->enhancementPS[i]=NULL;}
}
void ylf_fel_free(YLFFELContextRef f) { if(!f)return;ylf_fel_reset(f);if(f->base)CFRelease(f->base);free(f); }

static NSArray *ylf_fel_rationals(const AVRational *v,int n) {
  NSMutableArray *a=[NSMutableArray array];for(int i=0;i<n;i++){if(!v[i].den)return nil;[a addObject:@(av_q2d(v[i]))];}return [a copy];
}
static NSDictionary *ylf_fel_metadata(const AVDOVIMetadata *m) {
  const AVDOVIRpuDataHeader *h=av_dovi_get_header(m);
  const AVDOVIDataMapping *map=av_dovi_get_mapping(m);
  const AVDOVIColorMetadata *col=av_dovi_get_color(m);
  if(h->bl_bit_depth!=10||h->el_bit_depth!=10||h->vdr_bit_depth!=12||h->coef_log2_denom>32||
     h->ext_mapping_idc_0_4||h->ext_mapping_idc_5_7||map->mapping_color_space||map->mapping_chroma_format_idc!=0||
     (!h->disable_residual_flag && map->nlq_method_idc!=AV_DOVI_NLQ_LINEAR_DZ))return nil;
  double scale=ldexp(1.0,-h->coef_log2_denom), blMax=(1<<h->bl_bit_depth)-1,elMax=(1<<h->el_bit_depth)-1;
  NSMutableArray *np=[NSMutableArray array],*pv=[NSMutableArray array],*mt=[NSMutableArray array],*poly=[NSMutableArray array],
    *mo=[NSMutableArray array],*mc=[NSMutableArray array],*mm=[NSMutableArray array],*no=[NSMutableArray array],
    *ns=[NSMutableArray array],*nt=[NSMutableArray array],*nm=[NSMutableArray array];
  for(int c=0;c<3;c++) {
    const AVDOVIReshapingCurve *v=&map->curves[c];if(v->num_pivots<2||v->num_pivots>9)return nil;
    [np addObject:@(v->num_pivots)];
    for(int j=0;j<9;j++){if(j<v->num_pivots && (v->pivots[j]>blMax||(j&&v->pivots[j]<=v->pivots[j-1])))return nil;[pv addObject:@(j<v->num_pivots?v->pivots[j]/blMax:1)];}
    for(int j=0;j<8;j++){
      BOOL active=j<v->num_pivots-1;int method=active?v->mapping_idc[j]:0;
      if(method<0||method>1||(active&&method==0&&(v->poly_order[j]<1||v->poly_order[j]>2))||
         (active&&method==1&&(v->mmr_order[j]<1||v->mmr_order[j]>3)))return nil;
      [mt addObject:@(method)];[mo addObject:@(method?v->mmr_order[j]:0)];[mc addObject:@(method?v->mmr_constant[j]*scale:0)];
      for(int k=0;k<3;k++)[poly addObject:@(active&&!method&&k<=v->poly_order[j]?v->poly_coef[j][k]*scale:0)];
      for(int k=0;k<3;k++)for(int l=0;l<7;l++)[mm addObject:@(method&&k<v->mmr_order[j]?v->mmr_coef[j][k][l]*scale:0)];
    }
    const AVDOVINLQParams *n=&map->nlq[c];
    [no addObject:@(n->nlq_offset/elMax)];[ns addObject:@(elMax*scale*n->linear_deadzone_slope)];
    [nt addObject:@(scale*((double)n->linear_deadzone_threshold-0.5*n->linear_deadzone_slope))];[nm addObject:@(scale*n->vdr_in_max)];
  }
  NSArray *ycc=ylf_fel_rationals(col->ycc_to_rgb_matrix,9),*off=ylf_fel_rationals(col->ycc_to_rgb_offset,3),*lms=ylf_fel_rationals(col->rgb_to_lms_matrix,9);
  if(!ycc||!off||!lms||m->num_ext_blocks<0||m->num_ext_blocks>AV_DOVI_MAX_EXT_BLOCKS)return nil;
  NSMutableArray *display=[NSMutableArray array];
  for(int i=0;i<m->num_ext_blocks;i++){
    const AVDOVIDmData *e=av_dovi_get_ext(m,i);NSDictionary *values=@{};
    switch(e->level){
      case 1:values=@{@"minPQ":@(e->l1.min_pq),@"maxPQ":@(e->l1.max_pq),@"avgPQ":@(e->l1.avg_pq)};break;
      case 2:values=@{@"targetMaxPQ":@(e->l2.target_max_pq),@"trimSlope":@(e->l2.trim_slope),@"trimOffset":@(e->l2.trim_offset),@"trimPower":@(e->l2.trim_power),@"trimChromaWeight":@(e->l2.trim_chroma_weight),@"trimSaturationGain":@(e->l2.trim_saturation_gain),@"msWeight":@(e->l2.ms_weight)};break;
      case 3:values=@{@"minPQOffset":@(e->l3.min_pq_offset),@"maxPQOffset":@(e->l3.max_pq_offset),@"avgPQOffset":@(e->l3.avg_pq_offset)};break;
      case 4:values=@{@"anchorPQ":@(e->l4.anchor_pq),@"anchorPower":@(e->l4.anchor_power)};break;
      case 254:values=@{@"dmMode":@(e->l254.dm_mode),@"dmVersionIndex":@(e->l254.dm_version_index)};break;
      case 5:values=@{@"left":@(e->l5.left_offset),@"right":@(e->l5.right_offset),@"top":@(e->l5.top_offset),@"bottom":@(e->l5.bottom_offset)};break;
      case 6:values=@{@"maxLuminance":@(e->l6.max_luminance),@"minLuminance":@(e->l6.min_luminance),@"maxCLL":@(e->l6.max_cll),@"maxFALL":@(e->l6.max_fall)};break;
      default:break; // Level presence is retained so compositor must reject unsupported display processing.
    }
    [display addObject:@{@"level":@(e->level),@"values":values}];
  }
  return @{@"schemaVersion":@1,@"numPivots":[np copy],@"pivots":[pv copy],@"methods":[mt copy],@"polynomial":[poly copy],
    @"mmrOrder":[mo copy],@"mmrConstant":[mc copy],@"mmr":[mm copy],@"nlqOffset":[no copy],@"nlqSlope":[ns copy],
    @"nlqThreshold":[nt copy],@"nlqVdrInMax":[nm copy],@"yccToRGB":ycc,@"nonlinearOffset":off,@"rgbToLMS":lms,
    @"blBitDepth":@(h->bl_bit_depth),@"elBitDepth":@(h->el_bit_depth),@"outputBitDepth":@(h->vdr_bit_depth),
    @"signalEOTF":@(col->signal_eotf),@"signalColorSpace":@(col->signal_color_space),
    @"signalBitDepth":@(col->signal_bit_depth),@"signalFullRange":@(col->signal_full_range_flag),
    @"sourceMinPQ":@(col->source_min_pq),@"sourceMaxPQ":@(col->source_max_pq),
    @"numXPartitions":@(map->num_x_partitions),@"numYPartitions":@(map->num_y_partitions),
    @"residualEnabled":@(!h->disable_residual_flag),@"blFullRange":@(h->bl_video_full_range_flag),
    @"spatialResamplingFilter":@(h->spatial_resampling_filter_flag),@"elSpatialResamplingFilter":@(h->el_spatial_resampling_filter_flag),
    @"chromaResamplingExplicitFilter":@(h->chroma_resampling_explicit_filter_flag),@"displayMetadata":[display copy]};
}
static bool ylf_fel_matches_base_parameter(YLFFELContextRef f,const uint8_t *nal,size_t size) {
  size_t count=0, length=0;const uint8_t *bytes=NULL;
  if(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(f->base,0,&bytes,&length,&count,NULL))return false;
  for(size_t i=0;i<count;i++){
    if(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(f->base,i,&bytes,&length,NULL,NULL))return false;
    if(length==size&&!memcmp(bytes,nal,size))return true;
  }
  return false;
}
static void ylf_fel_append(NSMutableData *out,const uint8_t *p,size_t n) {
  uint8_t length[4]={(uint8_t)(n>>24),(uint8_t)(n>>16),(uint8_t)(n>>8),(uint8_t)n};
  [out appendBytes:length length:4];[out appendBytes:p length:n];
}
// Bounded length-prefixed access units. No stream/packet timestamp rewriting.
static int32_t ylf_fel_access(YLFFELContextRef f,YLFPacketRef packet,CFDictionaryRef *out) {
  if(!f||!packet||!packet->value||packet->value->stream_index!=f->streamIndex)return YLFResultInvalidArgument;
  AVPacket *p=packet->value;if(p->size<=0||p->size>32*1024*1024)return YLFResultVideoConfigurationInvalid;
  NSMutableData *bl=[NSMutableData data],*el=[NSMutableData data];NSData *rpu=nil;
  BOOL blVCL=NO,elVCL=NO,changed=NO;size_t offset=0;int nalCount=0;
  while(offset<(size_t)p->size){
    if(++nalCount>4096||p->size-offset<f->lengthSize)return YLFResultVideoConfigurationInvalid;
    size_t n=0;for(int i=0;i<f->lengthSize;i++)n=(n<<8)|p->data[offset++];
    if(n<2||n>p->size-offset)return YLFResultVideoConfigurationInvalid;
    const uint8_t *nal=p->data+offset;offset+=n;int type=(nal[0]>>1)&63;
    if((nal[0]&0x81)||(nal[1]&0xf8)||!(nal[1]&7))return YLFResultVideoConfigurationInvalid;
    if(type==62){if(rpu||n>65536)return YLFResultVideoConfigurationInvalid;rpu=[NSData dataWithBytes:nal length:n];}
    else if(type==63){
      nal+=2;n-=2;if(n<2||(nal[0]&0x81)||(nal[1]&0xf8)||!(nal[1]&7))return YLFResultVideoConfigurationInvalid;
      type=(nal[0]>>1)&63;if(type>=62)return YLFResultVideoConfigurationInvalid;
      if(type>=32&&type<=34){
        if(n>65536)return YLFResultVideoConfigurationInvalid;
        NSData *ps=[NSData dataWithBytes:nal length:n];
        if(!f->enhancementPS[type-32]||![ps isEqual:(__bridge NSData *)f->enhancementPS[type-32]]){
          // Decoder format changes require an explicit new probe/generation.
          if(f->enhancementPS[type-32])return YLFResultDolbyVisionUnsupported;
          f->enhancementPS[type-32]=CFBridgingRetain(ps);changed=YES;
        }
      }
      elVCL|=type<32;ylf_fel_append(el,nal,n);
    } else {
      if(type>=32&&type<=34&&!ylf_fel_matches_base_parameter(f,nal,n))return YLFResultDolbyVisionUnsupported;
      blVCL|=type<32;ylf_fel_append(bl,nal,n);
    }
  }
  if(!blVCL||!elVCL||!rpu)return YLFResultDolbyVisionUnsupported;
  if(changed||!f->enhancement){
    const uint8_t *ps[3];size_t sizes[3];
    for(int i=0;i<3;i++){if(!f->enhancementPS[i])return YLFResultVideoConfigurationInvalid;ps[i]=CFDataGetBytePtr(f->enhancementPS[i]);sizes[i]=CFDataGetLength(f->enhancementPS[i]);}
    CMVideoFormatDescriptionRef fmt=NULL;
    if(CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL,3,ps,sizes,4,NULL,&fmt))return YLFResultVideoConfigurationInvalid;
    if(f->enhancement)CFRelease(f->enhancement);f->enhancement=fmt;
  }
  // Remove HEVC emulation-prevention bytes before using FFmpeg's RPU parser.
  const uint8_t *src=rpu.bytes;NSMutableData *rbsp=[NSMutableData data];int zeros=0;
  for(size_t i=2;i<rpu.length;i++){
    uint8_t byte=src[i];if(zeros==2&&byte==3){if(i+1>=rpu.length||src[i+1]>3)return YLFResultVideoConfigurationInvalid;zeros=0;continue;}
    [rbsp appendBytes:&byte length:1];zeros=byte==0?MIN(zeros+1,2):0;
  }
  // FFmpeg bitreader requires padded input even though it checks syntax lengths.
  size_t payload=rbsp.length;
  // The upstream parser deliberately ignores unknown RPU types; that must not
  // accidentally reuse the previous frame's mapping in a strict FEL pipeline.
  const uint8_t *decoded=rbsp.bytes;
  if(payload<2||decoded[0]!=25||(decoded[1]>>2)!=2)return YLFResultVideoConfigurationInvalid;
  [rbsp increaseLengthBy:AV_INPUT_BUFFER_PADDING_SIZE];
  if(ff_dovi_rpu_parse(&f->dovi,rbsp.bytes,payload,AV_EF_CRCCHECK|AV_EF_EXPLODE)<0)return YLFResultVideoConfigurationInvalid;
  AVDOVIMetadata *parsed=NULL;
  if(ff_dovi_get_metadata(&f->dovi,&parsed)<=0||!parsed)return YLFResultVideoConfigurationInvalid;
  NSDictionary *metadata=ylf_fel_metadata(parsed);av_free(parsed);
  if(!metadata)return YLFResultDolbyVisionUnsupported;
  NSDictionary *unit=@{@"baseData":[bl copy],@"enhancementData":[el copy],@"baseFormat":(__bridge id)f->base,
     @"enhancementFormat":(__bridge id)f->enhancement,@"metadata":metadata,@"rpu":rpu};
  *out=CFBridgingRetain(unit);return 0;
}
int32_t ylf_fel_copy_access_unit(YLFFELContextRef f,YLFPacketRef p,CFDictionaryRef *out) {
  if(!out)return YLFResultInvalidArgument;*out=NULL;
  @autoreleasepool {int32_t result=ylf_fel_access(f,p,out);if(result)ylf_fel_reset(f);return result;}
}
