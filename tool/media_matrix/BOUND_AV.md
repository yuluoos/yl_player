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

## Public Flutter Android consumer

Build the existing example once with the explicit acceptance opt-in:

```sh
# From packages/yl_player/example
ORG_GRADLE_PROJECT_ylBoundAV=true flutter build apk --debug \
  -t integration_test/bound_av_test.dart
# From the repository root, without rebuilding during the run
python3 -B tool/media_matrix/run_bound_flutter_android.py \
  --apk packages/yl_player/example/build/app/outputs/flutter-apk/app-debug.apk \
  --serial <owned-device-serial> --out <new-directory>
```

The host passes its frozen plan at launch; the bridge hashes the installed APK
with bounded memory before exposing the plan. Product and Dart test share that
APK identity. The public controller/session/view drive all commands and keep the
actual Flutter texture. Native factories only observe the same engines under the
existing recovery policy. FLAC and VP9/Vorbis use Media3; the other four frozen
controls use the actual managed fallback. Each public session ID must match its
native observation, and public ready/first-frame/completion/disposal are required.

Flutter captures its real RepaintBoundary pixels. A single-use native clock token
pairs each capture with a fresh AudioTrack consumption observation within 200 ms.
No native ImageReader surface replaces the Flutter view. The raw gate and the
Flutter framework's final `allTestsPassed` result must both pass; a test-body
success flag is insufficient. `--negative-framework` fails after collecting all
six rows to exercise this distinction. `--negative-identity` rejects before any
playback. Retain both failures alongside the successful run.

The bridge and shared PCM observer compile only into opted-in debug builds and
instrumentation tests. Ordinary debug and release omit them, even when the
opt-in property is supplied to a release build. This remains a debug consumer
acceptance scope, not release, full-matrix, Apple-public, or physical-output proof.

## Apple public Flutter build-bound collection

The same `integration_test/bound_av_test.dart` drives the actual public controller,
session and view. Apple native surfaces are not captured by Flutter repaint-boundary
images: the opt-in observer reads the display layer attached by that session's
real platform view and pairs it with the real renderer's consumed audio clock.
The public session pauses before each snapshot, waits for presentation to settle,
and resumes afterwards. Native readback requires a zero-rate display timebase and
a paused/ended consumption observation; it never borrows a running estimate.
This is a sampled pause/resume protocol, not uninterrupted playback measurement.
It decorates the existing converter for post-trim PCM, preserving platform output,
product routing, decoder admission, and the fixed six-control denominator.

Compile with both Debug and explicit `-D YL_BOUND_AV`; the observation bridge and
its hooks are absent from ordinary Debug and Release. For macOS, from the example:

```sh
flutter build macos --debug --config-only -t integration_test/bound_av_test.dart
xcodebuild build -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/yl-bound-apple CODE_SIGNING_ALLOWED=NO \
  'OTHER_SWIFT_FLAGS=$(inherited) -D YL_BOUND_AV'
```

Then, from the repository root, launch the already-built product without rebuilding:

```sh
python3 -B tool/run_with_display_awake.py \
  python3 -B tool/media_matrix/run_bound_flutter_apple.py --platform macos \
  --app /tmp/yl-bound-apple/Build/Products/Debug/yl_player_example.app \
  --out /tmp/yl-bound-apple-run
```

For an equivalently built iOS Simulator app use `--platform ios --simulator UUID`.
The caller owns/boots that dedicated simulator. Every attempt needs a fresh output
directory. `--negative-identity` rejects the wrong product identity before playback;
`--negative-framework` fails the real Flutter test after the six raw records.

The product manifest includes Dart code and resources as well as native binaries;
product/test SHA are explicitly the same bundle identity. Runtime verification
hashes installed files and loaded product images, then repeats before status.
The host independently rejects file additions/removals/changes and requires the
same run's framework-final status. Partial raw rows remain diagnostic after a timeout.
Seek capture waits for actual audio reset and fresh phase output, even while the
public position callback still reports the prior phase. This remains a debug,
local clear-media acceptance scope, not physical screen/speaker or release proof.

Apple readback requires macOS 14.4 / iOS 17.4 or newer, independently of the
product deployment minimum. Run in a live GUI session. Preserve every attempt,
including missing display-layer output and framework timeouts; a single passing
run does not establish repeatability. The wrapper holds a temporary display-awake
assertion only for its owned run. Do not rebuild the bundle during collection.

## Complete catalog through the public Flutter path

Build the public `integration_test/bound_av_test.dart` product once with the
existing explicit debug opt-in, then keep its bytes unchanged:

```sh
python3 -B tool/media_matrix/run_bound_flutter_matrix.py --platform macos --app /absolute/frozen.app --out /absolute/new-run
python3 -B tool/media_matrix/run_bound_flutter_matrix.py --platform ios --app /absolute/frozen.app --simulator OWNED_UUID --out /absolute/new-run
python3 -B tool/media_matrix/run_bound_flutter_matrix.py --platform android --apk /absolute/frozen.apk --serial OWNED_SERIAL --out /absolute/new-run
```

The fixed catalog has 22 inputs in each of file and explicit managed HTTP: 40
required cells, two diagnostic MPEG-2 cells and two corrupt-input cells. Each
cell gets an independent run/session under one matrix/product identity. Failure
does not stop later cells or reduce the required denominator; decoder/transport
selection stays with the product. The local HTTP fixture server serves immutable
catalog bytes, requires the run header and records actual requests and bytes.
Native observers verify the actual source kind, exact URL, managed policy and
header independently of the plan. This is not an impairment or ABR tool.

`matrix-plan.json`, `records.json.gz`, each child's original extraction/status,
and `matrix-result.json` preserve both successes and failures. `bound_matrix.summarize`
replays raw evidence and requires final framework success, successful child exit,
no collector error, matching run/build/transport identities and unchanged product
bytes. Android additionally replays the original JSONL byte stream (not just its
valid prefix) and requires a successful extraction. A missing or malformed
required child cannot pass. The historical six-control runners remain available;
`--case` selects one diagnostic cell, never the complete denominator.

Mono sources retain actual output channels; Android may emit mono or duplicated
stereo only for a declared mono source, and the gate measures each actual channel.
Network seek waits for the actual native reset after public intent acknowledgement.
Owned fixture cleanup runs even if player disposal or unmount fails, preserving
an earlier playback failure. Android HTTP cancellation aborts calls on the caller,
while response-body close remains on the demux worker to avoid network reads on
Android's UI thread.

`formatScopeAcceptance` certifies only this fixed debug protocol if all 40 required
cells pass. `fullAcceptance` remains false: this does not certify release,
physical output, protected content, independent decoder references, all boundary
cases, minimum OS/Intel support or sustained thermal admission.

`matrix-progress.json` is explicitly provisional and cannot authorize acceptance;
the final replay is written to `matrix-result.json` only after collection. Every
seek phase waits for a freshly captured native consumption value at or beyond its
target, even if the public timeline still contains a larger pre-seek position.
Android returns that value only when the screenshot token matches its fresh real
playback-head sample; Apple retains its paused-readback protocol. Missing samples
remain bounded failures rather than empty phases accepted from stale public state.

### AVPlayer pre-effects observations

The opted-in Apple public observer attaches `MTAudioProcessingTap` to the actual
local AVPlayer item. It passes through source PCM unchanged, retains bounded raw
float samples and source ranges, and owns separate storage for each seek tap.
Tap finalization is observed before a successful row can be written.
Audio keeps running during pixel sampling; only the actual display layer is
temporarily frozen and restored. Repeated public pause/resume reprimes AVPlayer
and leaves holes in the observed PCM, so this route declares
`continuous-source-pull-v1`. Source-range duration and actual output frame count
are retained independently. Window selection maps frames within that source
interval; it does not establish sample-accurate hardware presentation times.

`avplayer-preeffects-source-pull` means **audio queue fill**, not the hardware
playback head. Apple exposes the source range being processed by the tap, not a
played-frame counter. The collector does not substitute `AVPlayer.currentTime`,
item timebase, host extrapolation, or another decoder as consumed audio.
`validate_render_pull` independently checks the existing raw PCM/pixel, identity,
lifecycle and source gates plus tap epoch and range/frame validity. The public
runner reports its result as `renderPullAcceptance`; framework failure, stale
identity or changed artifacts still reject it. `scopeAcceptance` and the complete
matrix remain false for these rows with `played_sample_clock_unverified`.

This diagnostic proof is limited to owned clear local assets with one audio
track and float32 mono/stereo tap output. Remote/DRM/multiple-track capture and
hardware consumption/physical output need separate evidence. Debug observers
remain excluded unless both `DEBUG` and `YL_BOUND_AV` are set.

API semantics: [Apple audio processing tap](https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtap),
[audio tap processor](https://developer.apple.com/documentation/avfoundation/avmutableaudiomixinputparameters/audiotapprocessor).
The local SDK `MTAudioProcessingTap.h` additionally specifies source-range,
real-time callback, and finalization contracts.
