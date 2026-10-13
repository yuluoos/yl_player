# Fresh final review: Matroska embedded VobSub

Repository /Users/yy2021_8689/Desktop/Flutter/yl_player; baseline01e65829930bc2acc9328de15018128b12322867.
Read-only review only. Do not edit files, commit, spawn agents or run concurrent Flutter commands. Read scoped diff/current files, report findings with severity and location plus explicit declined-to-judge areas. Ignore unrelated long-play/weakABR. Follow requesting-code-review/code-reviewer.md template.

User explicitly asks Matroska embedded VobSub discovery/selection/rendering with managed network, API comments, tests and commit. Existing approved P02 inline execution; no native/ABI/public enum/network path changes. Contract docs/superpowers/specs/2026-10-12-subtitle-embedded-vobsub.md; original plan docs/superpowers/plans/2026-09-26-remaining-02-tracks-subtitles.md; progress .superpowers/sdd/2026-09-26-remaining-02-tracks-subtitles/progress.md recent section.

Six production files: subtitles/{matroska_subtitles,subtitle_document,vobsub_parser,text_subtitle_runtime}.dart and {playback_session,player_controller}.dart. New support/embedded_vobsub_fixture.dart; embedded_vobsub_{test,parser_test,network_test,session_test}.dart and fixtures/embedded-vobsub-owned.mkv. Exact list/snapshot /private/tmp/yl_evob_validation.json. Full four-package test + analysis running in isolated archive+owned overlay; inspect /private/tmp/evob-final-four-packages.log and evob-final-analyze.log when ready, do not assume pass before end.

69 new directed tests passed (/private/tmp/evob-directed-final.log), 46 parser+6 file/budget+11 actualHTTP+6publicsession/widget. Entry RED unsupported before implementation. Isolated-only budgetmutation removes residual allowance, expected two testfailures observed then restored for final run. Own FFmpeg8.0.1 remux original IDX/SUB yields dvd_subtitle, raw46byteSPU, PTS1s, headerwithoutIDXrows; /private/tmp/evob-ffprobe.json. Ten native/build artifacthash unchanged.

Review focus deliberately inspect:
- shared _VobIndex embedded mode cannot relax external parser; header bounds/requiredpalette/size; ignores legacy IDX timestamp/id/langidx per Matroska guidance, rejects nonzero delay/nonneutraltransforms.
- raw oneSPU-perBlock, container nanosecondscale+CodecDelay->microseconds; SPU control start/stop/alpha still active; visibilityclip explicit/defaultduration, nextpacket/horizon; same-time replacement and malformed packet atomicity.
- bounded inputs and allocations across private+payload and across external/embedded/multipletracks; VobSub65535packet/10000globaltext+VobSubpacket; shared64MiBRGBA passed beforeallocation.
- managed reader/retry/conditionalETag/crossorigin credentials, cancellation/oldcatalog and statelessoffset/seek behavior; existing reader unchanged.
- tests assert actualpixel geometry/alpha animation, firstframe gate, text/bitmap switching, seek/off and image disposal; fakebackend not native/device claim.
- APIcomments public create/discover describe scope accurately.

Inherited excluded scope: advancedDVD effects/menus/compression/encryption/lacing; WebM/MP4VobSub; multipleresource/live/manifests; crossPeriod/audioidentity; native/device/HDR/protected/externaldisplay mapping; PD03/finalengineimagefailurepolicy. Prior MP4wvtt aggregate nestedbox accounting Minor stays deferred. Do not call these newly completed. Grade by real user effect, not narrow spec loopholes.
