# P02 continuation ledger

Baseline 68aa8c14; codex/p02-tracks-subtitles. P04 worktree left unchanged.
Execution inline, native builds serial; one independent final review.

Rulings:
- Retain approved bounded ASS/SSA/TTML/WebVTT subsets; no silent expansion to
  full-standard conformance. Existing unsupported effects stay documented.
- User has only iPhone and Mac; no authorized DRM configuration or additional
  display hardware. Complete available engineering/controlled verification;
  external physical acceptance remains open.
- User requested Device Hub observation. Xcode CoreDevice screenshot captures
  the specified physical iPhone; recording API reports unsupported. Screenshots
  cannot certify audible output or physical synchronization.
- Keep original strict pixel assertions. Two iPhone screenshot failures were
  traced to visible system volume HUD contamination; unchanged targeted cases
  passed. Preserve both failures and reruns.

Task 1: implemented. Native same-owner detach/remount plus public same-controller
seven-format remount with actual composed-pixel checks. macOS 8/8; Android 8/8.
Task 2: iPhone initial 11-case joint run 9/11; WebVTT/TTML targeted 2/2. Seven-format
visible sequence and audio identity pass, physical sound unverified. Final cleanup
correction complete iPhone rerun 11/11; additional DASH actual composition 4/4.
Task 3: production EOF seek bug reproduced on macOS, fixed, GREEN on macOS and
physical iPhone. Four Dart packages 2072/2072; four-package analysis clean. Native
Android run completed 8/8.
Task 4: final review 0/0/1; immediate independent addTearDown callbacks address
Minor. Final evidence/report freeze complete; deliver with the local commit containing this ledger.

Observed fault: paused successful seek from completed to an interior position
retained completed, hiding current subtitles. Repair changes state to paused
only for successful current user seek with paused intent and actual landing
before EOF. Seeking to EOF remains completed and playback does not restart.

Failure accounting: wrong initial root-relative command, observation JSON session
serialization error, actual EOF regression, two unsuccessful patch-script guards
and repeated RED, initial analyzer warnings, and volume-HUD image contamination
are retained. They are not counted as passing acceptance. Initial runs did not
freeze all source files; their available hashes and known differences remain
explicit. Final manifest identifies exact final sources.

Final cleanup: physical helpers stopped, original iproxy hash restored; owned
Android emulator stopped. Unrelated iPhone simulator untouched. No push/merge.
