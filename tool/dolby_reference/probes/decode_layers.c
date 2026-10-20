/* Research-only HEVC decoder. Does not render DV or apply trims. */
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libavutil/sha.h>

#define MAX_PACKET (8 * 1024 * 1024)
#define MAX_FRAME (64 * 1024 * 1024)
#define MAX_COUNT 32768

typedef struct PacketIdentity { uint32_t index; int poc; } PacketIdentity;

static uint64_t be(const uint8_t *p, int n) {
    uint64_t value = 0;
    for (int i = 0; i < n; ++i) value = (value << 8) | p[i];
    return value;
}
static int64_t signed_be(const uint8_t *p) {
    uint64_t bits = be(p, 8); int64_t value;
    memcpy(&value, &bits, sizeof(value)); return value;
}

static int drain(AVCodecContext *codec, AVFrame *frame, int eof, unsigned *count) {
    int status;
    while ((status = avcodec_receive_frame(codec, frame)) >= 0) {
        if (++*count > MAX_COUNT || frame->pts == AV_NOPTS_VALUE || frame->decode_error_flags ||
            !frame->opaque_ref || frame->opaque_ref->size != sizeof(PacketIdentity) ||
            frame->width <= 0 || frame->height <= 0 || frame->width > 4096 || frame->height > 2160)
            return -1;
        const char *format = av_get_pix_fmt_name(frame->format);
        if (!format || (strcmp(format, "yuv420p") && strcmp(format, "yuv420p10le") &&
                        strcmp(format, "yuv420p12le"))) return -1;
        int size = av_image_get_buffer_size(frame->format, frame->width, frame->height, 1);
        if (size <= 0 || size > MAX_FRAME) return -1;
        uint8_t *pixels = av_malloc(size);
        struct AVSHA *sha = av_sha_alloc();
        if (!pixels || !sha) { av_free(pixels); av_free(sha); return -1; }
        int copied = av_image_copy_to_buffer(pixels, size, (const uint8_t * const *)frame->data,
            frame->linesize, frame->format, frame->width, frame->height, 1);
        if (copied != size) { av_free(pixels); av_free(sha); return -1; }
        uint8_t hash[32]; char hex[65];
        av_sha_init(sha, 256); av_sha_update(sha, pixels, size); av_sha_final(sha, hash);
        av_free(pixels); av_free(sha);
        for (int i = 0; i < 32; ++i) sprintf(hex + 2*i, "%02x", hash[i]);
        PacketIdentity identity; memcpy(&identity, frame->opaque_ref->data, sizeof(identity));
        char type = av_get_picture_type_char(frame->pict_type);
        if (type != 'I' && type != 'P' && type != 'B') return -1;
        printf("{\"packet_index\":%" PRIu32 ",\"pts\":%" PRId64
               ",\"poc\":%d,\"width\":%d,\"height\":%d,\"pixel_format\":\"%s\","
               "\"picture_type\":\"%c\",\"pixels_sha256\":\"%s\"}\n",
               identity.index, frame->pts, identity.poc, frame->width, frame->height, format, type, hex);
        if (ferror(stdout)) return -1;
        av_frame_unref(frame);
    }
    return status == (eof ? AVERROR_EOF : AVERROR(EAGAIN)) ? 0 : -1;
}

int main(int argc, char **argv) {
    int result = 2; FILE *input = NULL; AVCodecContext *codec = NULL;
    AVPacket *packet = NULL; AVFrame *frame = NULL;
    AVCodecParserContext *parser = NULL; AVCodecContext *parse_context = NULL;
    av_log_set_level(AV_LOG_QUIET);
    if (argc != 2 || !(input = fopen(argv[1], "rb"))) goto done;
    struct stat info;
    if (fstat(fileno(input), &info) || !S_ISREG(info.st_mode) || info.st_size <= 0 ||
        info.st_size > 512 * 1024 * 1024) goto done;
    const AVCodec *implementation = avcodec_find_decoder_by_name("hevc");
    if (!implementation || !(codec = avcodec_alloc_context3(implementation))) goto done;
    parser = av_parser_init(AV_CODEC_ID_HEVC);
    parse_context = avcodec_alloc_context3(implementation);
    if (!parser || !parse_context) goto done;
    parser->flags |= PARSER_FLAG_COMPLETE_FRAMES;
    codec->thread_count = 1;
    codec->flags |= AV_CODEC_FLAG_COPY_OPAQUE;
    codec->err_recognition = AV_EF_CRCCHECK | AV_EF_BITSTREAM | AV_EF_BUFFER | AV_EF_EXPLODE;
    codec->max_pixels = 4096 * 2160;
    if (avcodec_open2(codec, implementation, NULL) < 0 || !(packet = av_packet_alloc()) ||
        !(frame = av_frame_alloc())) goto done;
    unsigned inputs = 0, outputs = 0;
    for (;;) {
        uint8_t header[24]; size_t got = fread(header, 1, sizeof(header), input);
        if (got == 0 && feof(input)) break;
        if (got != sizeof(header) || inputs >= MAX_COUNT) goto done;
        uint32_t index = (uint32_t)be(header + 16, 4), size = (uint32_t)be(header + 20, 4);
        if (index != inputs++ || !size || size > MAX_PACKET) goto done;
        if (av_new_packet(packet, size) < 0 || fread(packet->data, 1, size, input) != size) goto done;
        packet->pts = signed_be(header); packet->dts = signed_be(header + 8);
        if (packet->pts == AV_NOPTS_VALUE || packet->dts == AV_NOPTS_VALUE) goto done;
        /* A distinct HEVC parser computes POC from SPS/PPS/slice state. Reset the
           public field to a sentinel because parser APIs can swallow syntax errors. */
        parser->output_picture_number = INT_MIN;
        uint8_t *parsed = NULL; int parsed_size = 0;
        int used = av_parser_parse2(parser, parse_context, &parsed, &parsed_size,
            packet->data, packet->size, packet->pts, packet->dts, -1);
        if (used != packet->size || parsed_size != packet->size ||
            parser->output_picture_number == INT_MIN) goto done;
        PacketIdentity identity = {index, parser->output_picture_number};
        packet->opaque_ref = av_buffer_alloc(sizeof(identity));
        if (!packet->opaque_ref) goto done;
        memcpy(packet->opaque_ref->data, &identity, sizeof(identity));
        if (avcodec_send_packet(codec, packet) < 0 || drain(codec, frame, 0, &outputs)) goto done;
        av_packet_unref(packet);
    }
    if (!inputs || avcodec_send_packet(codec, NULL) < 0 || drain(codec, frame, 1, &outputs) ||
        outputs != inputs || fflush(stdout)) goto done;
    result = 0;
done:
    if (input) fclose(input);
    av_parser_close(parser); avcodec_free_context(&parse_context);
    av_frame_free(&frame); av_packet_free(&packet); avcodec_free_context(&codec);
    if (result) fputs("Decoded layer inspection failed\n", stderr);
    return result;
}
