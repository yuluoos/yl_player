#include <cassert>
#include <cmath>
#include <cstdio>

#include "../../android/src/main/cpp/YlAudioDownmix.h"

// Runs against real libswresample: ignoring metadata, treating zero as absent,
// using Lt/Rt coefficients for Lo/Ro, or retaining stale parameters changes PCM.
int main() {
  AVChannelLayout input = AV_CHANNEL_LAYOUT_5POINT1;
  AVChannelLayout output = AV_CHANNEL_LAYOUT_STEREO;
  SwrContext* resampler = nullptr;
  assert(swr_alloc_set_opts2(&resampler, &output, AV_SAMPLE_FMT_S16, 48000,
      &input, AV_SAMPLE_FMT_FLTP, 48000, 0, nullptr) == 0);
  assert(swr_init(resampler) == 0);
  YlAudioDownmix downmix;
  AVFrame* frame = av_frame_alloc();
  float samples[6][32] = {};
  const uint8_t* planes[6];
  for (int ch = 0; ch < 6; ++ch) planes[ch] = reinterpret_cast<uint8_t*>(samples[ch]);
  int16_t pcm[64];
  uint8_t* target[] = {reinterpret_cast<uint8_t*>(pcm)};
  int cases = 0;
  auto check = [&](int channel, double left, double right) {
    assert(downmix.apply(resampler, frame) == 0);
    for (int i = 0; i < 32; ++i) samples[channel][i] = 0.25f;
    assert(swr_convert(resampler, target, 32, planes, 32) == 32);
    assert(std::abs(pcm[0] / 8192.0 - left) < 0.0002);
    assert(std::abs(pcm[1] / 8192.0 - right) < 0.0002);
    for (int i = 0; i < 32; ++i) samples[channel][i] = 0;
    ++cases;
  };
  check(0, 0.41421356, 0); // No side data: original FFmpeg default.
  check(2, 0.29289322, 0.29289322);
  AVDownmixInfo* info = av_downmix_info_update_side_data(frame);
  assert(info);
  info->preferred_downmix_type = AV_DOWNMIX_TYPE_LTRT;
  info->center_mix_level = 1.0;
  info->surround_mix_level = 0.5;
  info->center_mix_level_ltrt = 0.25;
  info->surround_mix_level_ltrt = 0.25;
  info->lfe_mix_level = 1.0; // Only center/surround are in scope.
  check(2, 0.4, 0.4);
  check(4, 0.2, 0);
  check(5, 0, 0.2);
  check(3, 0, 0);
  check(0, 0.4, 0); // No extra gain.
  info->center_mix_level = 0;
  info->surround_mix_level = 0;
  check(2, 0, 0); // Zero is a valid coefficient.
  check(4, 0, 0);
  check(0, 1, 0);
  av_frame_remove_side_data(frame, AV_FRAME_DATA_DOWNMIX_INFO);
  check(2, 0.29289322, 0.29289322); // Missing metadata restores defaults.
  check(4, 0.29289322, 0);
  double volume, lfe;
  assert(av_opt_get_double(resampler, "rematrix_volume", 0, &volume) == 0 && volume == 1);
  assert(av_opt_get_double(resampler, "lfe_mix_level", 0, &lfe) == 0 && lfe == 0);
  av_frame_free(&frame);
  swr_free(&resampler);
  std::printf("PASS: %d real PCM downmix cases\n", cases);
}
