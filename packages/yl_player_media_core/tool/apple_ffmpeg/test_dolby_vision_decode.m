// Opt-in native integration probe. Supply local media and repaired hvcC paths;
// neither the media, configuration, nor decoded pixels are written by this test.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <YlFFmpegBridge/YlFFmpegBridge.h>

#define REQUIRE(condition) do { if (!(condition)) { \
  fprintf(stderr, "FAIL: %s (line %d)\n", #condition, __LINE__); exit(1); \
} } while (0)

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    REQUIRE(argc == 3);
    NSData *config = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
    REQUIRE(config.length > 0);
    YLFMediaContextRef context = NULL;
    YLFMediaInfo info = {0};
    REQUIRE(ylf_open_local(argv[1], &context, &info) == YLFResultOK);
    int32_t video = -1;
    for (int32_t i = 0; i < info.stream_count; i++) {
      YLFStreamInfo stream = {0};
      REQUIRE(ylf_copy_stream_info(context, i, &stream) == YLFResultOK);
      if (stream.kind == YLFStreamVideo) { video = i; break; }
    }
    REQUIRE(video >= 0);
    CMVideoFormatDescriptionRef format = NULL;
    REQUIRE(ylf_copy_video_format_description_with_codec_config(context, video,
        config.bytes, config.length, &format) == YLFResultOK);
    REQUIRE(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_DolbyVisionHEVC);
    CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(format);
    NSDictionary *atoms = ((__bridge NSDictionary *)extensions)[(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms];
    REQUIRE([atoms[@"dvcC"] length] == 24);
    NSDictionary *attributes = @{
      (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
      (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    VTDecompressionSessionRef session = NULL;
    OSStatus sessionStatus = VTDecompressionSessionCreate(kCFAllocatorDefault, format, NULL,
        (__bridge CFDictionaryRef)attributes, NULL, &session);
    fprintf(stderr, "VideoToolbox session status=%d\n", (int)sessionStatus);
    REQUIRE(sessionStatus == noErr);
    YLFPacketRef packet = NULL;
    do {
      ylf_packet_release(&packet);
      REQUIRE(ylf_read_packet(context, &packet) == YLFResultOK);
    } while (ylf_packet_stream_index(packet) != video || !ylf_packet_is_keyframe(packet));
    NSData *originalPacket = [NSData dataWithBytes:ylf_packet_data(packet) length:ylf_packet_size(packet)];
    CMSampleBufferRef sample = NULL;
    REQUIRE(ylf_create_video_sample_buffer(&packet, format, &sample) == YLFResultOK);
    REQUIRE(packet == NULL);
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    NSMutableData *sampleBytes = [NSMutableData dataWithLength:CMBlockBufferGetDataLength(block)];
    REQUIRE(CMBlockBufferCopyDataBytes(block, 0, sampleBytes.length, sampleBytes.mutableBytes) == noErr);
    REQUIRE([originalPacket isEqual:sampleBytes]);
    __block bool output = false;
    __block size_t rpuLength = 0;
    __block OSType pixelFormat = 0;
    REQUIRE(VTDecompressionSessionDecodeFrameWithOutputHandler(session, sample, 0, NULL,
        ^(OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime pts, CMTime duration) {
          REQUIRE(status == noErr && image != NULL);
          pixelFormat = CVPixelBufferGetPixelFormatType(image);
          REQUIRE(pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange);
          CFTypeRef rpu = CVBufferCopyAttachment(image, CFSTR("DolbyVisionRPUData"), NULL);
          REQUIRE(rpu && CFGetTypeID(rpu) == CFDataGetTypeID());
          rpuLength = (size_t)CFDataGetLength(rpu);
          REQUIRE(rpuLength > 0);
          CFRelease(rpu);
          output = true;
        }) == noErr);
    REQUIRE(VTDecompressionSessionFinishDelayedFrames(session) == noErr);
    REQUIRE(VTDecompressionSessionWaitForAsynchronousFrames(session) == noErr);
    REQUIRE(output);
    CFRelease(sample);
    VTDecompressionSessionInvalidate(session);
    CFRelease(session);
    CFRelease(format);
    ylf_close(&context);
    REQUIRE(ylf_debug_outstanding_packet_count() == 0);
    printf("PASS: packaged bridge dvh1 decode; pixel format=%u; RPU bytes=%zu; compressed packet unchanged; no outstanding packets\n", pixelFormat, rpuLength);
  }
  return 0;
}
