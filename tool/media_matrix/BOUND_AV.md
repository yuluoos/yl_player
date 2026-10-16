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
