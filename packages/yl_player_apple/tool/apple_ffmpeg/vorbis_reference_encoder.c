// Owned test tones encoded by the independently built Xiph library.
#include <vorbis/vorbisenc.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
static void pages(ogg_stream_state *stream, int flush) {
  ogg_page page;
  while ((flush ? ogg_stream_flush(stream, &page) : ogg_stream_pageout(stream, &page))) {
    if (fwrite(page.header, 1, page.header_len, stdout) != (size_t)page.header_len ||
        fwrite(page.body, 1, page.body_len, stdout) != (size_t)page.body_len) exit(2);
  }
}
int main(int argc, char **argv) {
  if (argc != 3) return 2;
  int rate = atoi(argv[1]), channels = atoi(argv[2]);
  if ((rate != 44100 && rate != 48000) || channels < 1 || channels > 2) return 2;
  vorbis_info info; vorbis_comment comment; vorbis_dsp_state dsp; vorbis_block block;
  ogg_stream_state stream; ogg_packet id, text, setup, packet;
  vorbis_info_init(&info); vorbis_comment_init(&comment);
  if (vorbis_encode_init_vbr(&info, channels, rate, 0.5) ||
      vorbis_analysis_init(&dsp, &info) || vorbis_block_init(&dsp, &block) ||
      ogg_stream_init(&stream, 100)) return 1;
  vorbis_analysis_headerout(&dsp, &comment, &id, &text, &setup);
  ogg_stream_packetin(&stream, &id); ogg_stream_packetin(&stream, &text); ogg_stream_packetin(&stream, &setup);
  pages(&stream, 1);
  int position = 0, total = 4 * rate;
  do {
    int frames = total - position; if (frames > 1024) frames = 1024;
    if (frames) {
      float **input = vorbis_analysis_buffer(&dsp, frames);
      for (int channel = 0; channel < channels; channel++) for (int i = 0; i < frames; i++) {
        double t = (position + i) / (double)rate;
        input[channel][i] = 0.04 * sin(2 * M_PI * (440 + channel * 55 + 220 * floor(t)) * t);
      }
    }
    vorbis_analysis_wrote(&dsp, frames); position += frames;
    while (vorbis_analysis_blockout(&dsp, &block) == 1) {
      vorbis_analysis(&block, NULL); vorbis_bitrate_addblock(&block);
      while (vorbis_bitrate_flushpacket(&dsp, &packet)) {
        ogg_stream_packetin(&stream, &packet); pages(&stream, 0);
      }
    }
    if (!frames) break;
  } while (1);
  pages(&stream, 1);
  ogg_stream_clear(&stream); vorbis_block_clear(&block); vorbis_dsp_clear(&dsp);
  vorbis_comment_clear(&comment); vorbis_info_clear(&info);
  return ferror(stdout) ? 2 : 0;
}
