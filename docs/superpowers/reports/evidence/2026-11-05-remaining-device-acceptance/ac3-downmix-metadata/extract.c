#include <assert.h>
#include <stdio.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/downmix_info.h>
int main(int argc, char **argv) {
  assert(argc == 2);
  AVFormatContext *format = NULL;
  assert(avformat_open_input(&format, argv[1], NULL, NULL) == 0);
  assert(avformat_find_stream_info(format, NULL) >= 0);
  int index = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
  assert(index >= 0);
  AVCodecParameters *parameters = format->streams[index]->codecpar;
  assert(parameters->codec_id == AV_CODEC_ID_AC3);
  const AVCodec *codec = avcodec_find_decoder(parameters->codec_id);
  AVCodecContext *context = avcodec_alloc_context3(codec);
  assert(avcodec_parameters_to_context(context, parameters) == 0);
  assert(avcodec_open2(context, codec, NULL) == 0);
  AVPacket *packet = av_packet_alloc();
  AVFrame *frame = av_frame_alloc();
  int frames = 0;
  double center = 0, surround = 0;
  while (av_read_frame(format, packet) >= 0) {
    if (packet->stream_index == index) {
      assert(avcodec_send_packet(context, packet) == 0);
      while (avcodec_receive_frame(context, frame) == 0) {
        AVFrameSideData *side = av_frame_get_side_data(frame, AV_FRAME_DATA_DOWNMIX_INFO);
        assert(side && frame->ch_layout.nb_channels == 6);
        AVDownmixInfo *info = (AVDownmixInfo *)side->data;
        if (frames) assert(center == info->center_mix_level && surround == info->surround_mix_level);
        center = info->center_mix_level; surround = info->surround_mix_level;
        frames++;
      }
    }
    av_packet_unref(packet);
  }
  assert(frames > 0);
  printf("{\"frames\":%d,\"center\":%.17g,\"surround\":%.17g,\"decoder\":\"%s\",\"ffmpeg\":\"%s\"}\n",frames,center,surround,codec->name,av_version_info());
  av_frame_free(&frame); av_packet_free(&packet); avcodec_free_context(&context); avformat_close_input(&format);
}
