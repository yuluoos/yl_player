# CI, Documentation, and Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the optimized repository continuously reproducible, document corrected public behavior and tested boundaries, and collect fresh evidence for every acceptance criterion.

**Architecture:** One GitHub Actions workflow runs independent foundation, Android, and iOS jobs using the same checked-in scripts and commands used locally. Documentation describes only verified behavior; physical-device and endurance evidence remains explicitly deferred.

**Tech Stack:** GitHub Actions, Flutter 3.44, Dart 3.12, Gradle/AGP 9, Xcode/iOS Simulator, shell verification scripts, Markdown.

**Spec:** `docs/superpowers/specs/2026-09-04-full-repository-optimization-design.md`

## Global Constraints

- Complete the Dart, Android, and iOS implementation plans before the final acceptance task.
- CI must run foundation, Android native, and iOS native/integration checks as separate jobs.
- CI uses repository scripts and must not silently skip a required suite.
- Minimum versions remain Android API 24, iOS 15, Dart 3.12, and Flutter 3.44.
- Documentation must not claim physical-device VideoToolbox, endurance, memory-profile, or long-duration acceptance without recorded evidence.
- No credentials, media URLs, or query strings may appear in logs or fixtures.
- Final success claims require fresh command output collected under `superpowers:verification-before-completion`.

## File Structure

- Create `.github/workflows/ci.yml`: three independent jobs with pinned platform/tool floors and concurrency cancellation.
- Create `tool/boot_ci_ios_simulator.sh`: deterministic available-simulator selection for CI.
- Modify `tool/check_foundation.sh` only if CI exposes a portability issue; retain all existing checks.
- Modify `tool/check_native_ios.sh` only if CI exposes a portability issue; retain all five integration suites.
- Modify `packages/yl_player/README.md`: corrected validation, error, decoder-policy, capability, and internal update semantics.
- Modify `docs/verification/ios-http-flv-hls-device-matrix.md` and `docs/verification/ios-mkv-device-matrix.md`: record simulator results and keep physical-device rows unverified.
- Create `docs/verification/full-repository-optimization.md`: dated acceptance evidence and deferred matrices.

---

### Task 1: Foundation and Android CI jobs

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: jobs named `foundation`, `android-native`, and later `ios-native-integration`.
- Foundation command: `sh tool/check_foundation.sh`.
- Android command: `./gradlew testDebugUnitTest` from `packages/yl_player_android/example/android`.

- [ ] **Step 1: Add the failing workflow-presence check locally**

Run before creating the file:

```bash
test -f .github/workflows/ci.yml
```

Expected: exit 1 because no CI workflow exists.

- [ ] **Step 2: Create the workflow with independent Linux jobs**

Use this structure:

```yaml
name: CI

on:
  push:
  pull_request:
  workflow_dispatch:

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  foundation:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v7
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.44.0'
          channel: stable
          cache: true
      - run: sh tool/check_foundation.sh

  android-native:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    defaults:
      run:
        working-directory: packages/yl_player_android/example/android
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-java@v6
        with:
          distribution: temurin
          java-version: '17'
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.44.0'
          channel: stable
          cache: true
      - run: flutter pub get
        working-directory: ${{ github.workspace }}
      - run: ./gradlew testDebugUnitTest --stacktrace
```

Correct the Android `flutter pub get` working directory to the repository root using `${{ github.workspace }}` rather than leaving it in the Gradle directory.

- [ ] **Step 3: Parse the workflow and run both job commands locally**

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/ci.yml", aliases: true); puts "workflow yaml ok"'
sh tool/check_foundation.sh
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest
```

Expected: YAML parses, foundation exits 0, and Android native tests pass.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: verify Dart and Android foundations"
```

### Task 2: Deterministic iOS simulator CI job

**Files:**
- Create: `tool/boot_ci_ios_simulator.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `tool/boot_ci_ios_simulator.sh` printing one booted simulator UDID to stdout and all diagnostics to stderr.
- Produces: `ios-native-integration` job invoking `sh tool/check_native_ios.sh` with `YL_IOS_SIMULATOR_ID`.

- [ ] **Step 1: Add the failing simulator-helper check**

```bash
test -x tool/boot_ci_ios_simulator.sh
```

Expected: exit 1 because the helper does not exist.

- [ ] **Step 2: Implement deterministic available-device selection**

Create a POSIX shell script with `set -eu`. First reuse a booted iPhone UDID parsed from `xcrun simctl list devices booted`; otherwise select the first available iPhone UDID from `xcrun simctl list devices available`, boot it, wait with `xcrun simctl bootstatus "$simulator_id" -b`, and print only the UDID. If none exists, print `No available iPhone Simulator was found.` to stderr and exit 1.

Use the same 36-character UDID extraction expression as `tool/check_native_ios.sh`:

```sh
sed -n 's/.*(\([0-9A-F-][0-9A-F-]*\)) (Booted).*/\1/p'
```

For shutdown devices, use the same expression with `(Shutdown)`.

Make the script executable:

```bash
chmod +x tool/boot_ci_ios_simulator.sh
```

- [ ] **Step 3: Add the macOS CI job**

Append:

```yaml
  ios-native-integration:
    runs-on: macos-15
    timeout-minutes: 60
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v7
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.44.0'
          channel: stable
          cache: true
      - run: flutter pub get
      - name: Boot iOS Simulator
        run: echo "YL_IOS_SIMULATOR_ID=$(sh tool/boot_ci_ios_simulator.sh)" >> "$GITHUB_ENV"
      - run: sh tool/check_native_ios.sh
```

Do not mark this job optional and do not add `continue-on-error`.

- [ ] **Step 4: Parse YAML and run the helper/native harness locally**

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/ci.yml", aliases: true); puts "workflow yaml ok"'
simulator_id=$(sh tool/boot_ci_ios_simulator.sh)
YL_IOS_SIMULATOR_ID="$simulator_id" sh tool/check_native_ios.sh
```

Expected: YAML parses, the helper returns exactly one booted UDID, XCTest passes, and all five integration suites pass.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml tool/boot_ci_ios_simulator.sh
git commit -m "ci: verify iOS native playback paths"
```

### Task 3: Public behavior and compatibility documentation

**Files:**
- Modify: `packages/yl_player/README.md`
- Modify: `docs/verification/ios-http-flv-hls-device-matrix.md`
- Modify: `docs/verification/ios-mkv-device-matrix.md`

**Interfaces:**
- Documents: runtime validation boundaries, state-authority rule, decoder policy, canonical MIME capability identifiers, and internal delta transport.
- Preserves: explicit separation between simulator evidence and unverified physical/endurance matrices.

- [ ] **Step 1: Add documentation assertions before editing**

Run:

```bash
rg -n "command rejection|hardwareOnly|video/avc|state delta|physical device" packages/yl_player/README.md docs/verification
```

Expected: at least the corrected command-rejection and state-delta language is absent.

- [ ] **Step 2: Update the README with exact semantics**

Document these statements without exposing internal class names:

- invalid configuration is rejected before native player creation in debug and release;
- seek must be nonnegative, speed must be finite in 0.25–4.0, volume finite in 0.0–1.0, quality fields positive, and retry/redirect counts 0–20;
- a rejected command completes with `YlPlayerError` but does not change `state` or emit `YlErrorEvent`; native terminal playback failures do both;
- `hardwareOnly` is the default; deprecated `preferHardware` has the same behavior; AVPlayer decoder selection remains system-managed;
- `hardwareVideoCodecs` uses MIME identifiers such as `video/avc` and `video/hevc`;
- position updates retain the public 250 ms default while the internal channel sends compact deltas after a full snapshot.

Replace the README example using `YlDecoderPolicy.preferHardware` with `YlDecoderPolicy.hardwareOnly`.

- [ ] **Step 3: Update verification matrices conservatively**

Record the date, simulator model/runtime, and commands used for current simulator checks. Preserve every physical-device/endurance row as `Not run` or `Unverified`; do not infer hardware VideoToolbox success from a simulator skip.

- [ ] **Step 4: Verify documentation statements match code/tests**

```bash
rg -n "preferHardware|hardwareOnly|video/avc|video/hevc|0\.25|4\.0|0\.0|1\.0|0.?20|250 ms" packages/yl_player/README.md
sh tool/check_foundation.sh
```

Expected: deprecated policy appears only in compatibility explanation, corrected limits are present, and foundation checks pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player/README.md docs/verification
git commit -m "docs: describe optimized player guarantees"
```

### Task 4: Repository-wide acceptance evidence

**Files:**
- Create: `docs/verification/full-repository-optimization.md`
- Modify only when a verification command exposes a defect: implementation files from the three preceding plans.

**Interfaces:**
- Produces: dated evidence for automated acceptance and an explicit deferred-validation list.

- [ ] **Step 1: Invoke the completion-verification discipline**

Before making any success claim, read and follow `superpowers:verification-before-completion`. Record fresh output from every command below; prior runs are not evidence for this step.

- [ ] **Step 2: Run foundation checks**

```bash
sh tool/check_foundation.sh
```

Expected: `flutter analyze`, formatting, seven Dart/example test groups, and the iOS FFmpeg build contract all exit 0.

- [ ] **Step 3: Run Android native checks**

```bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --warning-mode all
```

Expected: all existing and new native tests pass; no deprecated `android.newDsl` or `android.builtInKotlin` warning appears.

- [ ] **Step 4: Run iOS native and integration checks**

```bash
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
simulator_id=$(sh tool/boot_ci_ios_simulator.sh)
YL_IOS_SIMULATOR_ID="$simulator_id" sh tool/check_native_ios.sh
```

Expected: XCTest and all five integration suites pass, with only the existing explicitly justified simulator hardware-decode skip permitted.

- [ ] **Step 5: Run security, duplication, protocol, and cleanliness audits**

```bash
rg -n "Authorization|Cookie|Proxy-Authorization" packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAndroidNetwork.kt
test ! -e packages/yl_player_android/lib/src/channel_codec.dart
test ! -e packages/yl_player_ios/lib/src/channel_codec.dart
rg -n '"stateDelta"|"protocolVersion"|"generation"' packages/yl_player_android/android/src/main packages/yl_player_ios/ios/yl_player_ios/Sources
if rg -n '"droppedFrames"' packages/yl_player_ios/ios/yl_player_ios/Sources; then exit 1; fi
git diff --check
git status --short
```

Expected: all three credential names occur in the sanitizer; duplicate codecs are absent; both native implementations emit version/generation deltas; legacy `droppedFrames` emits nowhere; no whitespace errors; status contains only the intended verification document before its commit.

- [ ] **Step 6: Write the evidence document**

Record:

```markdown
# Full Repository Optimization Verification

Date: 2026-09-04

## Automated evidence

- Foundation: PASS — `sh tool/check_foundation.sh`
- Android native: PASS — `./gradlew testDebugUnitTest --warning-mode all`
- iOS native/integration: PASS — `sh tool/check_native_ios.sh`
- Contract audits: PASS — redirect, protocol, duplication, and metric-key checks

## Deferred evidence

- Android TV physical-device endurance: UNVERIFIED
- Physical iOS VideoToolbox availability: UNVERIFIED
- Long-duration playback and reconnect soak: UNVERIFIED
- Instruments/ETTrace/memgraph profiling: UNVERIFIED
```

Add actual test counts, simulator identity/runtime, skipped-test reason, and relevant warning status from the fresh output. Do not write PASS for any failed or unrun command.

- [ ] **Step 7: Commit evidence and perform final clean check**

```bash
git add docs/verification/full-repository-optimization.md
git commit -m "test: record repository optimization verification"
git status --short
```

Expected: commit succeeds and final `git status --short` is empty.
