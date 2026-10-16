# Same-run native consumer A/V evidence

`run_bound_apple.py` and `run_bound_android.py` consume **already built** artifacts.
Build once, invoke the collector with a new output directory, and never rebuild
or overwrite that directory during collection. Each collector persists the
planned six controls and product/test identity before launch, verifies the
installed/loaded bytes in-process, then verifies host artifacts again afterward.
A Git revision is context, not an executable identity.

Apple hashes canonical sorted manifests of the product app and separate XCTest
bundle. Framework symlink aliases are omitted while their actual files are
hashed. Loaded product images must match those frozen file hashes. Android's
instrumented library APK contains both production Kotlin/JNI and tests, so the
same APK digest explicitly fills both roles. It is not a release Flutter APK.

Each player gets a new session ID. A retained row contains actual published
center pixels, the native audio-output consumption clock observed with
those pixels, decoded/trimmed PCM windows, initial completion, three seeks and
resource release. The independent gate decodes raw Float32 PCM, checks its hash,
frequency and channel identity/downmix, and requires repeated matching image /
audio-clock observations. These are output-boundary observations, not microphone
or display measurements; they do not certify physical lip sync or acoustic output.

A scope passes only when all frozen controls pass, native tests pass, extraction
succeeds and artifact hashes remain unchanged. Unsupported decoder rows remain
required failures. `fullAcceptance` is always false: this six-control native
route does not cover the complete format matrix or public Flutter lifecycle.
`--negative-identity` deliberately supplies a wrong expected build digest; the
native test must fail before playback and produce no accepted rows.

Example after the existing native build-for-testing step:

```sh
python3 -B tool/media_matrix/run_bound_apple.py \
  --xctestrun <Products/Runner_macosx27.0-arm64.xctestrun> \
  --app <Products/Debug/yl_player_example.app> \
  --tests <app/Contents/PlugIns/RunnerTests.xctest> \
  --platform macos --destination 'platform=macOS,arch=arm64' --out <new-directory>
python3 -B tool/media_matrix/run_bound_android.py \
  --apk <yl_player_android-debug-androidTest.apk> \
  --serial <owned-device-serial> --out <new-directory>
```

Keep `plan.json`, manifests, `launch.json`, native logs/summary, `rows.json.gz`,
`result.json` and failed attempts together. Raw PCM in the gzip remains independently
recheckable via `bound_av.validate(plan, rows)`. Original `.xcresult` and installed
APKs remain local build artifacts; archives identify their inputs and extracted
records without checking large executables into source control.

Android freezes an engine per control: `webm-vp9-vorbis` uses the product
`YlMedia3Engine`/Core and its hardware codec policy; the other five use the
native fallback. Media3 rows must name the initialized video and audio codecs.
A test-only factory observes post-trim PCM without replacing the default sink's
real AudioTrack. Its fresh playback head is paired with ImageReader pixels;
player position estimates are never consumption evidence. The collector is
restricted to clear local 48 kHz stereo PCM16 at 1x without silence skipping.
Renderer stream offset is subtracted once from the first sink buffer timestamp;
flush invalidates that origin and fences seek phases. Empty pipeline drains emit
no samples. Disposal requires acknowledgement and all created tracks released.
These internal observation seams are unavailable for protected playback and have
no public Flutter API. Production factory, surface and codec defaults stay intact.
