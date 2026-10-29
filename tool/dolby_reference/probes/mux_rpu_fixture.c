/* Test fixture only: append one framed RPU per local MP4 packet, keeping PTS/DTS.
 * Not a Dolby encoder, production muxer, or independent picture reference. */
#include <libavformat/avformat.h>
#include <libavutil/intreadwrite.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    AVFormatContext *input = NULL, *output = NULL;
    AVPacket *packet = NULL;
    FILE *rpus = NULL;
    AVDictionary *options = NULL;
    int status = 2, error, count = 0;
    if (argc != 4 || access(argv[3], F_OK) == 0) goto done;
    rpus = fopen(argv[2], "rb");
    if (!rpus) goto done;
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    if (avformat_open_input(&input, argv[1], av_find_input_format("mov"), &options) < 0) goto done;
    if (avformat_find_stream_info(input, NULL) < 0 || input->nb_streams != 1) goto done;
    AVStream *source = input->streams[0];
    AVCodecParameters *codec = source->codecpar;
    if (codec->codec_id != AV_CODEC_ID_HEVC || codec->extradata_size < 23 ||
        (codec->extradata[21] & 3) != 3) goto done;
    if (avformat_alloc_output_context2(&output, NULL, "mp4", argv[3]) < 0) goto done;
    AVStream *target = avformat_new_stream(output, NULL);
    if (!target || avcodec_parameters_copy(target->codecpar, codec) < 0) goto done;
    target->time_base = source->time_base;
    if (avio_open(&output->pb, argv[3], AVIO_FLAG_WRITE) < 0 ||
        avformat_write_header(output, NULL) < 0) goto done;
    packet = av_packet_alloc();
    if (!packet) goto done;
    while ((error = av_read_frame(input, packet)) >= 0) {
        uint8_t size_bytes[4];
        if (++count > 32768 || packet->stream_index != 0 || packet->size > 8*1024*1024 ||
            fread(size_bytes, 1, 4, rpus) != 4) goto done;
        unsigned size = AV_RB32(size_bytes);
        if (size < 3 || size > 1024*1024) goto done;
        int start = packet->size;
        if (av_grow_packet(packet, (int)size + 4) < 0) goto done;
        AV_WB32(packet->data + start, size);
        if (fread(packet->data + start + 4, 1, size, rpus) != size ||
            packet->data[start+4] != 0x7c || packet->data[start+5] != 1) goto done;
        av_packet_rescale_ts(packet, source->time_base, target->time_base);
        if (av_interleaved_write_frame(output, packet) < 0) goto done;
        av_packet_unref(packet);
    }
    if (error != AVERROR_EOF || !count || fgetc(rpus) != EOF || ferror(rpus) ||
        av_write_trailer(output) < 0) goto done;
    status = 0;
done:
    av_packet_free(&packet);
    av_dict_free(&options);
    if (rpus) fclose(rpus);
    avformat_close_input(&input);
    if (output) {
        if (output->pb) avio_closep(&output->pb);
        avformat_free_context(output);
    }
    if (status) fprintf(stderr, "synthetic RPU fixture mux failed\n");
    return status;
}
