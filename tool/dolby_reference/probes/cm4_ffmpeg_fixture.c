/* Test-only independent parser oracle: native FFmpeg frame side data.
 * No project metadata resolver or RPU mutation is used here. */
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/dovi_meta.h>
#include <inttypes.h>
#include <stdio.h>
#define FIELD(s, f) printf("\"" #f "\":%u,", (unsigned)(s).f)
#define LAST(s, f) printf("\"" #f "\":%u", (unsigned)(s).f)
/* Keep FFmpeg's exact signed rational representation, never round to floats. */
static void primaries(const char *prefix, const AVColorPrimariesDesc *p) {
    const AVCIExy points[4] = {p->prim.r, p->prim.g, p->prim.b, p->wp};
    const char *names[4] = {"red", "green", "blue", "white"};
    for (int i=0;i<4;i++) {
        printf(",\"%s_primary_%s_x\":[%d,%d],\"%s_primary_%s_y\":[%d,%d]",
               prefix,names[i],points[i].x.num,points[i].x.den,
               prefix,names[i],points[i].y.num,points[i].y.den);
    }
}
static int block(const AVDOVIDmData *b) {
    printf("{\"level\":%u,\"payload\":{", b->level);
    switch (b->level) {
    case 1: FIELD(b->l1,min_pq); FIELD(b->l1,max_pq); LAST(b->l1,avg_pq); break;
    case 3: FIELD(b->l3,min_pq_offset); FIELD(b->l3,max_pq_offset); LAST(b->l3,avg_pq_offset); break;
    case 5:
        printf("\"active_area_left_offset\":%u,\"active_area_right_offset\":%u,\"active_area_top_offset\":%u,\"active_area_bottom_offset\":%u",
               b->l5.left_offset,b->l5.right_offset,b->l5.top_offset,b->l5.bottom_offset); break;
    case 6:
        printf("\"max_display_mastering_luminance\":%u,\"min_display_mastering_luminance\":%u,\"max_content_light_level\":%u,\"max_frame_average_light_level\":%u",
               b->l6.max_luminance,b->l6.min_luminance,b->l6.max_cll,b->l6.max_fall); break;
    case 8:
        FIELD(b->l8,target_display_index); FIELD(b->l8,trim_slope); FIELD(b->l8,trim_offset);
        FIELD(b->l8,trim_power); FIELD(b->l8,trim_chroma_weight); FIELD(b->l8,trim_saturation_gain);
        FIELD(b->l8,ms_weight); FIELD(b->l8,target_mid_contrast); FIELD(b->l8,clip_trim);
        for (int i=0;i<6;i++) printf("\"saturation_vector_field%d\":%u,",i,b->l8.saturation_vector_field[i]);
        for (int i=0;i<6;i++) printf("\"hue_vector_field%d\":%u%s",i,b->l8.hue_vector_field[i],i==5?"":",");
        break;
    case 9:
        LAST(b->l9,source_primary_index);
        if (b->l9.source_primary_index==255) primaries("source",&b->l9.source_display_primaries);
        break;
    case 10:
        FIELD(b->l10,target_display_index); FIELD(b->l10,target_max_pq); FIELD(b->l10,target_min_pq); LAST(b->l10,target_primary_index);
        if (b->l10.target_primary_index==255) primaries("target",&b->l10.target_display_primaries);
        break;
    case 11:
        FIELD(b->l11,content_type); FIELD(b->l11,whitepoint); FIELD(b->l11,reference_mode_flag);
        printf("\"reserved_byte2\":%u,\"reserved_byte3\":%u",
               (b->l11.sharpness<<6)|(b->l11.noise_reduction<<4)|(b->l11.mpeg_noise_reduction<<2)|b->l11.frame_rate_conversion,
               (b->l11.brightness<<6)|(b->l11.color<<4)); break;
    case 254: FIELD(b->l254,dm_mode); LAST(b->l254,dm_version_index); break;
    default: return -1;
    }
    printf("}}"); return 0;
}
static int drain(AVCodecContext *codec, AVFrame *frame, int eof, int *count) {
    int result;
    while ((result=avcodec_receive_frame(codec,frame))>=0) {
        AVFrameSideData *side=av_frame_get_side_data(frame,AV_FRAME_DATA_DOVI_METADATA);
        if (!side || frame->pts==AV_NOPTS_VALUE || ++*count>32768 || frame->decode_error_flags) return -1;
        const AVDOVIMetadata *dm=(const AVDOVIMetadata *)side->data;
        if (dm->num_ext_blocks<0 || dm->num_ext_blocks>AV_DOVI_MAX_EXT_BLOCKS) return -1;
        printf("{\"pts\":%"PRId64",\"blocks\":[",frame->pts);
        for (int i=0;i<dm->num_ext_blocks;i++) {
            if (i) printf(",");
            if (block(av_dovi_get_ext(dm,i))) return -1;
        }
        printf("]}\n"); av_frame_unref(frame);
    }
    return result==(eof?AVERROR_EOF:AVERROR(EAGAIN))?0:-1;
}
int main(int argc,char **argv) {
    AVFormatContext *input=NULL; AVCodecContext *codec=NULL; AVPacket *packet=NULL;
    AVFrame *frame=NULL; AVDictionary *options=NULL; int status=2,inputs=0,outputs=0,error;
    if (argc!=2) goto done;
    av_dict_set(&options,"protocol_whitelist","file",0);
    if (avformat_open_input(&input,argv[1],av_find_input_format("mov"),&options)<0 ||
        avformat_find_stream_info(input,NULL)<0 || input->nb_streams!=1 ||
        input->streams[0]->codecpar->codec_id!=AV_CODEC_ID_HEVC) goto done;
    codec=avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_HEVC));
    if (!codec || avcodec_parameters_to_context(codec,input->streams[0]->codecpar)<0) goto done;
    codec->thread_count=1; codec->err_recognition=AV_EF_EXPLODE|AV_EF_CRCCHECK;
    if (avcodec_open2(codec,codec->codec,NULL)<0) goto done;
    packet=av_packet_alloc();frame=av_frame_alloc();if (!packet || !frame) goto done;
    while ((error=av_read_frame(input,packet))>=0) {
        if (++inputs>32768 || packet->stream_index!=0 || avcodec_send_packet(codec,packet)<0 || drain(codec,frame,0,&outputs)) goto done;
        av_packet_unref(packet);
    }
    if (error!=AVERROR_EOF || !inputs || avcodec_send_packet(codec,NULL)<0 || drain(codec,frame,1,&outputs) || inputs!=outputs || fflush(stdout)) goto done;
    status=0;
done:
    av_dict_free(&options);av_frame_free(&frame);av_packet_free(&packet);avcodec_free_context(&codec);avformat_close_input(&input);
    if (status) fprintf(stderr,"FFmpeg CM4 fixture inspection failed\n");
    return status;
}
