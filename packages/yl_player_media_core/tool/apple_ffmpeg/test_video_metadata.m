// Native CoreMedia regression tests. No user media is embedded in this file.
// Include the implementation so malformed FFmpeg metadata can be exercised
// without exposing test-only mutators in the bridge's public ABI.
#include "../../darwin/native/YlFFmpegBridge/YlFFmpegBridge.m"
#include <libavutil/dovi_meta.h>
#include <libavutil/mastering_display_metadata.h>

static int failures = 0;
static int checks = 0;
#define CHECK(condition, message) do { \
  checks++; \
  if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); failures++; } \
} while (0)

static NSData *configuration(void) {
  // VPS/SPS/PPS from an independently generated 64x64 black Main10 frame:
  // ffmpeg -f lavfi -i color=black:s=64x64:r=1 -frames:v 1
  // -pix_fmt yuv420p10le -c:v libx265
  // -x265-params colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc
  // Encoder-info SEI was removed from the hvcC arrays.
  NSString *hex = @"0102200000009000000000001ef000fcfdfafa00000f03200001001840010c01ffff02200000030090000003000003001e959809210001002d42010102200000030090000003000003001ea0208104d96566924caf016a12201208000003000800000300084022000100074401c172b42240";
  NSMutableData *data = [NSMutableData data];
  for (NSUInteger i = 0; i < hex.length; i += 2) {
    uint8_t byte = (uint8_t)strtoul([[hex substringWithRange:NSMakeRange(i, 2)] UTF8String], NULL, 16);
    [data appendBytes:&byte length:1];
  }
  return data;
}

static NSDictionary *extensions(CMVideoFormatDescriptionRef format) {
  return format ? (__bridge NSDictionary *)CMFormatDescriptionGetExtensions(format) : @{};
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSData *config = configuration();
    struct YLFMediaContext context = {0};
    context.format = avformat_alloc_context();
    AVStream *stream = avformat_new_stream(context.format, NULL);
    AVCodecParameters *parameters = stream->codecpar;
    parameters->codec_type = AVMEDIA_TYPE_VIDEO;
    parameters->codec_id = AV_CODEC_ID_HEVC;
    parameters->extradata = av_mallocz(config.length + AV_INPUT_BUFFER_PADDING_SIZE);
    memcpy(parameters->extradata, config.bytes, config.length);
    parameters->extradata_size = (int)config.length;
    parameters->color_primaries = AVCOL_PRI_BT2020;
    parameters->color_trc = AVCOL_TRC_ARIB_STD_B67;
    parameters->color_space = AVCOL_SPC_BT2020_NCL;
    parameters->color_range = AVCOL_RANGE_JPEG;
    CMVideoFormatDescriptionRef format = NULL;
    CHECK(ylf_copy_video_format_description(&context, 0, &format) == YLFResultOK, "synthetic HEVC format creation");
    CHECK([extensions(format)[(__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction] isEqual:(__bridge NSString *)kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG], "track HLG overrides parameter-set PQ");
    CHECK([extensions(format)[(__bridge NSString *)kCMFormatDescriptionExtension_FullRangeVideo] boolValue], "track full range is preserved");
    if (format) CFRelease(format);

    AVMasteringDisplayMetadata *mastering = av_mastering_display_metadata_alloc();
    mastering->has_primaries = 1; mastering->has_luminance = 1;
    mastering->display_primaries[0][0] = (AVRational){34000, 50000};
    mastering->display_primaries[0][1] = (AVRational){16000, 50000};
    mastering->display_primaries[1][0] = (AVRational){13250, 50000};
    mastering->display_primaries[1][1] = (AVRational){34500, 50000};
    mastering->display_primaries[2][0] = (AVRational){7500, 50000};
    mastering->display_primaries[2][1] = (AVRational){3000, 50000};
    mastering->white_point[0] = (AVRational){15635, 50000};
    mastering->white_point[1] = (AVRational){16450, 50000};
    mastering->max_luminance = (AVRational){1000, 1};
    mastering->min_luminance = (AVRational){1, 10000};
    av_packet_side_data_add(&parameters->coded_side_data, &parameters->nb_coded_side_data,
                           AV_PKT_DATA_MASTERING_DISPLAY_METADATA, (uint8_t *)mastering, sizeof(*mastering), 0);
    size_t light_size;
    AVContentLightMetadata *light = av_content_light_metadata_alloc(&light_size);
    light->MaxCLL = 1000; light->MaxFALL = 400;
    av_packet_side_data_add(&parameters->coded_side_data, &parameters->nb_coded_side_data,
                           AV_PKT_DATA_CONTENT_LIGHT_LEVEL, (uint8_t *)light, light_size, 0);
    parameters->color_trc = AVCOL_TRC_SMPTE2084;
    parameters->color_range = AVCOL_RANGE_MPEG;
    CHECK(ylf_copy_video_format_description_with_codec_config(&context, 0, config.bytes, config.length, &format) == YLFResultOK, "HDR10 with recovered configuration accepted");
    CHECK([extensions(format)[(__bridge NSString *)kCMFormatDescriptionExtension_ColorPrimaries] isEqual:(__bridge NSString *)kCMFormatDescriptionColorPrimaries_ITU_R_2020], "HDR10 BT2020 primaries");
    CHECK([extensions(format)[(__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction] isEqual:(__bridge NSString *)kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ], "HDR10 PQ transfer");
    CHECK([extensions(format)[(__bridge NSString *)kCMFormatDescriptionExtension_YCbCrMatrix] isEqual:(__bridge NSString *)kCMFormatDescriptionYCbCrMatrix_ITU_R_2020], "HDR10 BT2020 matrix");
    CHECK([extensions(format)[(__bridge NSString *)kCMFormatDescriptionExtension_FullRangeVideo] isEqual:@NO], "HDR10 limited range");
    const uint8_t expectedMastering[] = {0x33,0xc2,0x86,0xc4,0x1d,0x4c,0x0b,0xb8,0x84,0xd0,0x3e,0x80,0x3d,0x13,0x40,0x42,0,0x98,0x96,0x80,0,0,0,1};
    const uint8_t expectedLight[] = {3, 0xe8, 1, 0x90};
    CHECK([extensions(format)[(__bridge NSString *)kCMFormatDescriptionExtension_MasteringDisplayColorVolume] isEqual:[NSData dataWithBytes:expectedMastering length:24]], "mastering color volume encodes GBR order and luminance units");
    CHECK([extensions(format)[(__bridge NSString *)kCMFormatDescriptionExtension_ContentLightLevelInfo] isEqual:[NSData dataWithBytes:expectedLight length:4]], "content light levels retained");
    if (format) CFRelease(format);
    mastering->min_luminance.den = 0;
    CHECK(ylf_copy_video_format_description(&context, 0, &format) == YLFResultVideoConfigurationInvalid && !format, "zero denominator HDR metadata rejected");
    mastering->min_luminance.den = 10000;
    light->MaxCLL = 65536;
    CHECK(ylf_copy_video_format_description(&context, 0, &format) == YLFResultVideoConfigurationInvalid && !format, "out-of-range content light value rejected");
    av_packet_side_data_free(&parameters->coded_side_data, &parameters->nb_coded_side_data);

    size_t dovi_size = 0;
    AVDOVIDecoderConfigurationRecord *dovi = av_dovi_alloc(&dovi_size);
    dovi->dv_version_major = 1; dovi->dv_version_minor = 0;
    dovi->dv_profile = 5; dovi->dv_level = 6;
    dovi->rpu_present_flag = 1; dovi->el_present_flag = 0; dovi->bl_present_flag = 1;
    dovi->dv_bl_signal_compatibility_id = 0;
    av_packet_side_data_add(&parameters->coded_side_data, &parameters->nb_coded_side_data,
                           AV_PKT_DATA_DOVI_CONF, (uint8_t *)dovi, dovi_size, 0);
    CHECK(ylf_copy_video_format_description(&context, 0, &format) == YLFResultOK, "Dolby Vision Profile 5 format creation");
    CHECK(format && CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_DolbyVisionHEVC, "Dolby Vision uses dvh1 instead of hvc1");
    NSDictionary *atoms = extensions(format)[(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms];
    NSData *dvcc = atoms[@"dvcC"];
    const uint8_t expected[24] = {1, 0, 10, 53, 0};
    CHECK(dvcc.length == 24 && memcmp(dvcc.bytes, expected, sizeof(expected)) == 0, "dvcC contains parsed Profile 5 level 6 RPU/BL metadata");
    CHECK(extensions(format)[(__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction] == nil, "Profile 5 does not inherit ordinary PQ color interpretation");
    CHECK([extensions(format)[(__bridge NSString *)kCMFormatDescriptionExtension_FullRangeVideo] isEqual:@YES], "Profile 5 is full range despite container range");
    if (format) CFRelease(format);
    uint8_t *fields[] = {&dovi->dv_version_major, &dovi->dv_version_minor,
      &dovi->dv_profile, &dovi->dv_level, &dovi->rpu_present_flag,
      &dovi->el_present_flag, &dovi->bl_present_flag,
      &dovi->dv_bl_signal_compatibility_id, &dovi->dv_md_compression};
    const uint8_t invalid[] = {0, 1, 7, 0, 0, 1, 0, 1, 1};
    for (size_t i = 0; i < sizeof(invalid); i++) {
      uint8_t original = *fields[i]; *fields[i] = invalid[i];
      CHECK(ylf_copy_video_format_description(&context, 0, &format) == YLFResultVideoConfigurationInvalid && format == NULL, "unsupported or malformed Dolby Vision fields fail closed");
      *fields[i] = original;
    }
    dovi->dv_profile = 7; dovi->el_present_flag = 1;
    dovi->dv_bl_signal_compatibility_id = 6;
    CHECK(ylf_copy_video_format_description(&context, 0, &format) == YLFResultDolbyVisionUnsupported && !format, "valid Profile 7 reports unsupported Dolby Vision without HEVC fallback");
    CHECK(ylf_copy_video_format_description_with_codec_config(&context, 0, config.bytes, config.length, &format) == YLFResultDolbyVisionUnsupported && !format, "recovered config preserves unsupported Dolby Vision result");
    dovi->bl_present_flag = 0;
    CHECK(ylf_copy_video_format_description(&context, 0, &format) == YLFResultVideoConfigurationInvalid && !format, "malformed Profile 7 stays configuration invalid");
    dovi->bl_present_flag = 1;
    dovi->dv_profile = 8; dovi->el_present_flag = 0;
    dovi->dv_bl_signal_compatibility_id = 1;
    CHECK(ylf_copy_video_format_description(&context, 0, &format) == YLFResultDolbyVisionUnsupported && !format, "valid Profile 8 reports unsupported Dolby Vision");
    dovi->dv_profile = 5; dovi->dv_bl_signal_compatibility_id = 0;
    parameters->coded_side_data[0].size = 1;
    CHECK(ylf_copy_video_format_description(&context, 0, &format) == YLFResultVideoConfigurationInvalid && !format, "truncated parsed Dolby Vision struct rejected");
    parameters->coded_side_data[0].size = dovi_size;
    CHECK(ylf_copy_video_format_description_with_codec_config(&context, -1, config.bytes, config.length, &format) == YLFResultVideoConfigurationInvalid && !format, "invalid stream index rejected");
    CHECK(ylf_copy_video_format_description_with_codec_config(&context, 0, NULL, config.length, &format) == YLFResultVideoConfigurationInvalid && !format, "null recovered config rejected");
    CHECK(ylf_copy_video_format_description_with_codec_config(&context, 0, config.bytes, 10, &format) == YLFResultVideoConfigurationInvalid && !format, "truncated recovered config rejected");
    CHECK(ylf_copy_video_format_description_from_codec_config(YLFCodecHEVC, config.bytes, config.length, &format) == YLFResultOK && CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC, "legacy codec-only factory remains ordinary HEVC");
    if (format) CFRelease(format);
    avformat_free_context(context.format);
    if (argc == 3) {
      YLFMediaContextRef real = NULL;
      YLFMediaInfo info = {0};
      CHECK(ylf_open_local(argv[1], &real, &info) == YLFResultOK, "open temporary original media prefix");
      if (real) {
        NSData *repaired = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
        AVCodecParameters *p = real->format->streams[0]->codecpar;
        NSData *original = [NSData dataWithBytes:p->extradata length:p->extradata_size];
        CHECK(ylf_copy_video_format_description_with_codec_config(real, 0, repaired.bytes, repaired.length, &format) == YLFResultOK, "real repaired configuration accepted");
        CHECK(format && CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_DolbyVisionHEVC, "actual stream retains Dolby Vision after configuration repair");
        CHECK([original isEqual:[NSData dataWithBytes:p->extradata length:p->extradata_size]], "recovered factory leaves original track configuration untouched");
        if (format) CFRelease(format);
        ylf_close(&real);
      }
    }
    fprintf(stderr, "Video metadata regression: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
  }
}
