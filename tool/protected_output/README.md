# Protected-output view feasibility probe

This is an **example Debug-only clear-media prototype**, not a plugin capability
or DRM implementation. Apple embeds the canonical Swift source into its existing
example runner files with `sync_apple_probe.py`; Android registers a `src/debug`
factory by reflection from MainActivity, with no factory in release builds.
Production player code, Pigeon schemas and default rendering are unchanged.

```sh
python3 tool/protected_output/sync_apple_probe.py --check
cd packages/yl_player/example
flutter test integration_test/protected_view_probe_test.dart -d macos
flutter test integration_test/protected_view_probe_test.dart -d <iOS-simulator-id>
YL_ANDROID_DEVICE_ID=<device-id> sh ../../../tool/run_android_integration.sh integration_test/protected_view_probe_test.dart
```

The test joins original owned DASH video init + four fragments into a temporary
local fMP4, without remuxing. Inputs are pinned by `dash_timeline/SHA256SUMS`.
No DRM stream, certificate, key, license, network request or protected pixel
capture is involved. Native factories accept at most four identities and local
files no larger than 8 MiB; the channel is for trusted example tests only.

Apple uses AVPlayerLayer readiness and current item time, a new player/layer for
each replacement, and weak view ownership. Android uses a secure-requested
SurfaceView, explicit hybrid composition and Media3 first-frame callbacks fenced
by epoch and player identity. SurfaceView owns its Surface; release detaches and
releases the decoder/player, never releases the holder's Surface directly.

The test observes two identities, first-frame association, clock progress,
portrait-shaped resize, replacement isolation, explicit dispose and unmount/reset.
It does not prove DRM decryption, secure decoding, screenshot resistance, HDCP,
physical visibility, precise audio/video sync, subtitle overlay, rotation/crop
correctness, memory-leak absence or minimum-OS support. See the DRM contract and
P06 execution report for remaining gates. `pixelReadback=false` and
`protectionVerified=false` are declared probe scope, not security telemetry.
