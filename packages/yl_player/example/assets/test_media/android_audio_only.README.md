Android-only integration fixture, synthesized locally with FFmpeg. No external media.

Command (run from repository root, create only this file):

```sh
ffmpeg -hide_banner -loglevel error -f lavfi -i sine=frequency=440:sample_rate=48000:duration=12 -c:a aac -b:a 64k -movflags +faststart packages/yl_player/example/assets/test_media/android_audio_only.m4a
```

12 seconds, 48 kHz mono AAC in an MP4 container; no video track. The Android
integration suite verifies decoded audio tracks are present and video tracks are
absent. Existing Apple baseline fixtures are not regenerated.
