# P02 device acceptance continuation

Continue the approved P02 plans inline using executing-plans. Baseline: 68aa8c14.
Spec: 2026-09-20-playback-expansion-requirements.md and
2026-10-14-p02-runtime-completion.md. Existing accepted bounded format subsets
remain unchanged. User now prioritizes all P02 work over P04 and confirms the
previous iPhone and Mac are available; DRM configuration and additional display
hardware are unavailable. Missing external evidence must remain explicit.

## Tasks

1. Close same-owner native-view detach/remount coverage. Keep both native players
   alive, remove only the first view, remount it, check ownership/epoch, subtitle
   pixels and advancing playback. Exercise actual public YlPlayerView lifecycle
   separately: a clear probe alone does not validate production view behavior.
2. Run physical iPhone multi-audio identity/selection and seven subtitle formats.
   Add a visible, bounded manual run for audible track distinction and subtitle
   selected/off/offset/seek/pause/remount behavior; preserve automated assertions
   and separately attribute human observations. Do not label clock samples as
   physical synchronization measurements.
3. Run current affected Dart suites and analysis; native integrations sequentially
   on available platforms. Fix any observed production fault with a behavioral
   RED followed by GREEN. Retain failed attempts and source hashes.
4. Map every original P02 requirement to implementation and evidence. One final
   independent review of the continuation, address important findings, freeze
   evidence and commit locally. External DRM/HDR/HDCP/minimum-OS acceptance stays
   open if required inputs remain missing; never mark complete by deleting scope.

## Review focus

Same-player remount vs player replacement; stale subtitle clearing; bounded image
resources; audio identity vs audible output; real frame/clock evidence vs ACK;
user-owned devices/processes and complete cleanup; honest missing-input matrix.


## Execution outcome

Tasks 1–3 implemented and verified: same-owner native probe and production-view
remount, physical iPhone 11/11, macOS 8/8, Android 8/8, four Dart packages
2072/2072 and clean analysis. Observed AVPlayer completed-seek failure has actual
RED/GREEN evidence and a guarded production fix. Final review: 0/0/1; immediate
independent teardown registration addresses the Minor and passed final device
regression. Task 4 requirement mapping, review and evidence sealing are complete; the local commit contains the deliverable. Additional iPhone DASH composition passed 4/4; full
physical acceptance remains open for explicitly unavailable inputs. See the
[current report](../reports/2026-09-26-remaining-02-tracks-subtitles.md).
