# One final read-only review

Reviewer: fresh `gpt-6-astra`, high effort, no inherited conversation. Reviewed
owned diff and new files against `2026-10-11-subtitle-embedded.md`. No edits or
native/device/long-play/ABR tests by reviewer. One review, one fix pass, no second
review. Pre-fix full regression was 940/940; static analysis clean.

## Findings and rulings

1. **Important/P2 accepted:** `ReferencePriority` (0xFA) presence unconditionally
   marked a subtitle BlockGroup unsupported. Its specified default is zero;
   explicitly storing zero is semantically neutral. Regression with
   `block(extra: uint(0xfa, 0))` failed as predicted. Accept zero, continue to
   reject nonzero priorities. Source checked by author and reviewer:
   https://www.rfc-editor.org/rfc/rfc9559.html#section-5.1.3.5.4 .
   Cost if wrong: incorrect handling of a nonneutral cache dependency; bounded
   nonzero rejection retained to avoid claiming it.
2. **Minor/P3 regraded required contract fix:** checking 32 enabled subtitle
   tracks before `FlagEnabled=0` meant a later disabled entry caused overflow.
   Contract explicitly limits enabled tracks; an input-order-dependent false
   rejection violates it. Check disabled before enabled-count admission.
   Both disabled-first and disabled-last are tested. Existing 128 total-track
   limit remains. Cost if wrong: additional disabled metadata admitted within
   the unchanged total-track and element bounds; no unbounded allocation claim.

Combined RED: 52 pass, 2 fail. One implementation pass. GREEN: 54/54. No Critical,
no outstanding Important, no deferred Minor. Final four-package results and
fingerprints are recorded in manifest.json.

## Scope judgments

The reviewer found no confirmed stale publication, cross-origin catalog loss,
UID remapping, timestamp conversion or aggregate-budget bypass in reviewed code.
ASS/SSA fields and ReadOrder were checked against the primary Matroska mapping:
https://www.matroska.org/technical/subtitles.html . This is bounded review evidence,
not proof of every possible container or decoder behavior.

Declined to judge physical/native decoding, long-play, weak-network ABR and
explicitly excluded containers/codecs. Author ruling: keep these as open scope;
this slice is real local-file parsing and Flutter rendering, with a fake public
video backend. Cost: native-device synchronization and broad container coverage
still require later work. No implication of complete P02/CAP-SUB acceptance.

Scope decision by author: implement the first embedded route through the existing
Dart subtitle owner; native bridges currently expose no subtitle packets. This
avoids adding new native decoding paths in a shared checkout during other
playback work. It supports local stable MKV UTF8/ASS/SSA only. Unsupported enabled
subtitle codecs reject the whole candidate catalog, preserving the old one.
