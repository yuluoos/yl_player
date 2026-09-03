#ifndef YL_FFMPEG_BRIDGE_H
#define YL_FFMPEG_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

#if __has_attribute(visibility)
#define YLF_EXPORT __attribute__((visibility("default")))
#else
#define YLF_EXPORT
#endif

YLF_EXPORT const char *ylf_build_configuration(void);
YLF_EXPORT const char *ylf_ffmpeg_version(void);

#ifdef __cplusplus
}
#endif

#endif
