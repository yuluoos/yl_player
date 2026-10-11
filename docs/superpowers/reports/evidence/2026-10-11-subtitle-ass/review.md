# Independent final review and resolution

One read-only review by ass_final_review (gpt-6-astra, high), as required by
executing-plans. No review edits, native/device jobs, or second review.

Three Important findings: (1) total run budget enforced after whole document
allocation; (2) six-argument move zero/zero jumped to endpoint; (3) named reset
left argumentless override defaults bound to the event's original style.
One Minor: CRLF counted twice. Regraded Important because it changes the
advertised accepted input budget based solely on line ending convention.
All four received failing regression tests before fixes. Budget now propagates
the remaining catalog allowance into ASS parsing and checks before run creation.
A snapshot mutation removing that propagation proves the aggregate regression
fails (late unsupported payload wins), then final restored code passes.

Additional pixel tests exposed independently: fading separate outline/fill
passes bleeds outline color through fill; Flutter text shadows omit outline
expansion. Fixed by cue-wide faded composition and explicit shadow outline/fill
passes. Mixed shadow offsets per cue reject explicitly to retain the bounded
four-painter implementation. Nine anchor and shadow boxes are manually derived.

Review declined: full libass equivalence/smart wrap/complex effects/fonts;
three-platform real-font/HDR/protected acceptance; PGS/VobSub/embedded tracks;
long-play/ABR and concurrent edits. These remain open as declared by the slice
contract; no whole-P02 or device acceptance is claimed. No deferred minor issue.
