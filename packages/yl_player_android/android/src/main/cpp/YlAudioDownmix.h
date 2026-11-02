#pragma once

extern "C" {
#include <libavutil/downmix_info.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
}

struct YlAudioDownmix {
  static constexpr double kDefaultMixLevel = 0.7071067811865475244;
  double center = kDefaultMixLevel;
  double surround = kDefaultMixLevel;

  int apply(SwrContext* resampler, const AVFrame* frame) {
    const AVFrameSideData* side = av_frame_get_side_data(frame, AV_FRAME_DATA_DOWNMIX_INFO);
    const auto* info = side ? reinterpret_cast<const AVDownmixInfo*>(side->data) : nullptr;
    // Keep the existing ordinary Lo/Ro stereo matrix; Lt/Rt coefficients belong
    // to a different matrix encoding. Zero is a valid, intentional mix level.
    const double next_center = info ? info->center_mix_level : kDefaultMixLevel;
    const double next_surround = info ? info->surround_mix_level : kDefaultMixLevel;
    if (next_center == center && next_surround == surround) return 0;
    int result = av_opt_set_double(resampler, "center_mix_level", next_center, 0);
    if (result < 0) return result;
    result = av_opt_set_double(resampler, "surround_mix_level", next_surround, 0);
    if (result < 0) return result;
    // Both callers keep the input sample rate, so there is no resampling tail
    // to discard. Rebuild only when the frame's mix levels change.
    result = swr_init(resampler);
    if (result < 0) return result;
    center = next_center;
    surround = next_surround;
    return 0;
  }
};
