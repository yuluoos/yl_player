// Compare real avcC demux bytes with the production artifact's CMSampleBuffer.
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <YlFFmpegBridge/YlFFmpegBridge.h>

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 2) return 2;
    YLFMediaContextRef context = NULL;
    YLFMediaInfo info = {0};
    if (ylf_open_local(argv[1], &context, &info) != YLFResultOK) return 2;
    uint8_t config[1024];
    size_t configSize = ylf_stream_codec_config_size(context, 0);
    if (configSize == 0 || configSize > sizeof(config) ||
        ylf_copy_stream_codec_config(context, 0, config, sizeof(config)) != YLFResultOK ||
        config[0] != 1) return 3;
    CMVideoFormatDescriptionRef format = NULL;
    if (ylf_copy_video_format_description(context, 0, &format) != YLFResultOK) return 3;
    int videos = 0, changed = 0, ambiguous = 0;
    while (videos < 100) {
      YLFPacketRef packet = NULL;
      if (ylf_read_packet(context, &packet) != YLFResultOK) break;
      if (ylf_packet_stream_index(packet) != 0) {
        ylf_packet_release(&packet);
        continue;
      }
      size_t size = ylf_packet_size(packet);
      NSData *before = [NSData dataWithBytes:ylf_packet_data(packet) length:size];
      const uint8_t *bytes = before.bytes;
      if (size >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1) ambiguous++;
      int64_t pts = ylf_packet_pts_us(packet);
      CMSampleBufferRef sample = NULL;
      if (ylf_create_video_sample_buffer(&packet, format, &sample) != YLFResultOK) return 4;
      CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
      size_t outputSize = CMBlockBufferGetDataLength(block);
      NSMutableData *after = [NSMutableData dataWithLength:outputSize];
      if (CMBlockBufferCopyDataBytes(block, 0, outputSize, after.mutableBytes) != kCMBlockBufferNoErr) return 4;
      if (![before isEqualToData:after]) {
        fprintf(stderr, "MISMATCH video=%d ptsUs=%lld input=%zu output=%zu\n", videos, pts, size, outputSize);
        changed++;
      }
      CFRelease(sample);
      ylf_packet_release(&packet);
      videos++;
    }
    CFRelease(format);
    ylf_close(&context);
    fprintf(stderr, "length-prefix regression: videoPackets=%d ambiguous=%d changed=%d outstanding=%d\n",
        videos, ambiguous, changed, ylf_debug_outstanding_packet_count());
    return videos == 100 && ambiguous > 0 && changed == 0 && ylf_debug_outstanding_packet_count() == 0 ? 0 : 1;
  }
}
