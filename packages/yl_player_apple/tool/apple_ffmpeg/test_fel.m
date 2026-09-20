#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
#include <assert.h>
int main(int argc, const char **argv) { @autoreleasepool {
  YLFFELContextRef fel = NULL;
  assert(ylf_fel_create(NULL, 0, &fel) < 0 && !fel);
  assert(ylf_stream_dolby_vision_profile(NULL, 0) == 0);
  if (argc < 2) return 0;
  YLFMediaContextRef media = NULL; YLFMediaInfo info;
  assert(ylf_open_local(argv[1], &media, &info) == 0);
  assert(ylf_stream_dolby_vision_profile(media, 0) == 7);
  assert(ylf_fel_create(media, 0, &fel) == 0 && fel);
  int count = 0; YLFPacketRef pkt = NULL;
  while (ylf_read_packet(media, &pkt) == 0) {
    if (ylf_packet_stream_index(pkt) == 0) {
      CFDictionaryRef au = NULL;
      assert(ylf_fel_copy_access_unit(fel, pkt, &au) == 0 && au);
      NSDictionary *d = (__bridge NSDictionary *)au;
      assert([d[@"baseData"] length] && [d[@"enhancementData"] length] && [d[@"rpu"] length]);
      assert([d[@"metadata"][@"numPivots"] count] == 3);
      if(count==0){
        AVDOVIMetadata *parsed=NULL;assert(ff_dovi_get_metadata(&fel->dovi,&parsed)>0);
        AVDOVIRpuDataHeader *header=av_dovi_get_header(parsed);
        AVDOVIDataMapping *mapping=av_dovi_get_mapping(parsed);
        uint8_t depth=header->bl_bit_depth;header->bl_bit_depth=8;assert(!ylf_fel_metadata(parsed));header->bl_bit_depth=depth;
        uint8_t pivots=mapping->curves[0].num_pivots;mapping->curves[0].num_pivots=10;assert(!ylf_fel_metadata(parsed));mapping->curves[0].num_pivots=pivots;
        uint16_t pivot=mapping->curves[0].pivots[1];mapping->curves[0].pivots[1]=0;assert(!ylf_fel_metadata(parsed));mapping->curves[0].pivots[1]=pivot;
        enum AVDOVIMappingMethod method=mapping->curves[0].mapping_idc[0];mapping->curves[0].mapping_idc[0]=99;assert(!ylf_fel_metadata(parsed));mapping->curves[0].mapping_idc[0]=method;
        assert(ylf_fel_metadata(parsed));av_free(parsed);
        fprintf(stderr,"FEL display metadata: %s\n",[d[@"metadata"][@"displayMetadata"] description].UTF8String);
        for(int omitted=62;omitted<=63;omitted++){
          NSMutableData *filtered=[NSMutableData data];size_t pos=0;
          while(pos<(size_t)pkt->value->size){size_t start=pos,n=0;for(int j=0;j<fel->lengthSize;j++)n=(n<<8)|pkt->value->data[pos++];
            if(((pkt->value->data[pos]>>1)&63)!=omitted)[filtered appendBytes:pkt->value->data+start length:n+fel->lengthSize];pos+=n;}
          AVPacket *missing=av_packet_alloc();av_new_packet(missing,(int)filtered.length);memcpy(missing->data,filtered.bytes,filtered.length);missing->stream_index=0;
          struct YLFPacket wrapped={.value=missing};YLFFELContextRef test=NULL;assert(ylf_fel_clone(fel,&test)==0);
          CFDictionaryRef result=NULL;assert(ylf_fel_copy_access_unit(test,&wrapped,&result)<0&&!result);
          ylf_fel_free(test);av_packet_free(&missing);
        }
        YLFFELContextRef owner=NULL;assert(ylf_fel_clone(fel,&owner)==0);CFDictionaryRef owned=NULL;
        assert(ylf_fel_copy_access_unit(owner,pkt,&owned)==0);ylf_fel_reset(owner);ylf_fel_free(owner);
        assert([((__bridge NSDictionary *)owned)[@"rpu"] length]>0);CFRelease(owned);
        YLFFELContextRef clone=NULL;assert(ylf_fel_clone(fel,&clone)==0);
        assert(clone->enhancement && !clone->dovi.mapping);ylf_fel_free(clone);
        // Unknown RPU types must fail even with an existing valid mapping.
        YLFFELContextRef unknown=NULL;assert(ylf_fel_clone(fel,&unknown)==0);CFDictionaryRef prior=NULL;
        assert(ylf_fel_copy_access_unit(unknown,pkt,&prior)==0);CFRelease(prior);
        AVPacket *unknownPacket=av_packet_clone(pkt->value);assert(av_packet_make_writable(unknownPacket)==0);
        size_t at=0;while(at<(size_t)unknownPacket->size){size_t n=0;for(int j=0;j<fel->lengthSize;j++)n=(n<<8)|unknownPacket->data[at++];
          if(((unknownPacket->data[at]>>1)&63)==62){assert(n>3);unknownPacket->data[at+3]=0;break;}at+=n;}
        struct YLFPacket unknownWrapper={.value=unknownPacket};CFDictionaryRef unknownResult=NULL;
        assert(ylf_fel_copy_access_unit(unknown,&unknownWrapper,&unknownResult)<0&&!unknownResult&&!unknown->dovi.mapping);
        av_packet_free(&unknownPacket);ylf_fel_free(unknown);
        AVPacket *bad=av_packet_clone(pkt->value);struct YLFPacket wrapper={.value=bad};
        YLFFELContextRef malformed=NULL;assert(ylf_fel_clone(fel,&malformed)==0);
        bad->size=3;CFDictionaryRef result=(CFDictionaryRef)1;
        assert(ylf_fel_copy_access_unit(malformed,&wrapper,&result)<0&&!result);
        assert(!malformed->dovi.mapping);av_packet_free(&bad);ylf_fel_free(malformed);
      }
      // The dictionary remains valid across parser reset/context release; bytes
      // are independent of the AVPacket and no nested mutable containers leak.
      assert(CFGetTypeID((__bridge CFTypeRef)d[@"metadata"]) == CFDictionaryGetTypeID());
      CFRelease(au); count++;
    }
    ylf_packet_release(&pkt);
  }
  assert(count > 0); ylf_fel_reset(fel); ylf_fel_free(fel); ylf_close(&media);
  printf("FEL actual prefix: %d access units passed\n", count);
} }
