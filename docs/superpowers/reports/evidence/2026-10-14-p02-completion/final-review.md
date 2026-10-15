# P02 fresh final review

Reviewer: fresh-context gpt-6-astra, high; read-only; no delegated reviewers.
Range: c3b8b902341638ffd8c96c3c2744c52d1c60471b..b55f1de0aa4a4cec4df2fcb8f0561efe808f0a81
plus uncommitted Task4 integration/API/report changes. Final verification still
running at review time; reviewer did not relabel those as passed.

## Strengths

Generation/cue/active-set guards isolate bitmap failures and release partial/late
images. Protected capability defaults closed; external managed resources stay
independent and protected discovery fails before I/O. ASS has independent pixel,
Unicode, styles and font-change tests with active-only caching. Seven-format
integration measures actual areas and honestly separates physical evidence.

## Important — accepted and fixed

ass_wrap.dart probe shaping happened before budget subtraction; an indivisible
line broke out before subtraction. 512 alternating-size Ahem glyph runs in a
2-pixel aperture produced 257 shaped paragraphs, violating one initial +128 local
bound. Reserve the possible three measurements before each probe. Regression
observed 257>129 RED, then43 with no additional measurement on same-widget rebuild
GREEN. Initial cache check inadvertently changed GlobalKey; corrected fixture to
preserve widget identity. Full affected suite result is in task4.json.

## Minor — deferred

protected_view_probe_test.dart unmounts then resets, without remounting the same
live player. Off/on only removes subtitles. Therefore this new native integration
does not measure same-player detach/remount with subtitles; prior native/bridge
lifecycle tests are separate evidence. Matrix explicitly records this limit.

## Session-first-frame finding — ruled, not blocking

The controller uses a session first-frame milestone, whereas the native bridge
tracks view/revision readiness. Current-time clear subtitles can precede the new
video frame on the native black cover after remount. Current contract explicitly
uses session milestone; native cover still protects video. No pixel leak or
texture downgrade found. Per-view subtitle blackout would require a new observable
readiness contract, not clearing a one-shot session Future.

## Declined to judge and executor rulings

- Licensed DRM/physical stacking/HDCP/external reconnect/HDR brightness/colors/
  physical A/V sync/minimum-OS devices: unavailable authorized inputs; stays open.
- Full libass/font attachments/advanced ASS/TTML: outside approved bounded subset;
  explicit unsupported effects are not a full-standard compatibility claim.
- Long-play/weak-network ABR/P05: explicitly excluded by user, unchanged here.

Verdict: With fixes (0 Critical,1 Important,1 Minor). Executor accepted Important,
performed one RED→GREEN fix pass and final verification. No second reviewer was
requested. Final evidence sealing belongs to the executor, not this review.
