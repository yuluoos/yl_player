#import "YlFFmpegBridge.h"

#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

const char *ylf_build_configuration(void) {
  return avformat_configuration();
}

const char *ylf_ffmpeg_version(void) {
  return av_version_info();
}
