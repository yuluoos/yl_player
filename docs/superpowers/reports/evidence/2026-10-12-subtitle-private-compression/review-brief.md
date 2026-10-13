# Fresh final review: Matroska CodecPrivate compression

Repo /Users/yy2021_8689/Desktop/Flutter/yl_player; base866afa00d25ffa7f256a0d3583ae791d35683325.
Read-only one review: no edits/commits/subagents/Flutter commands. Follow requesting-code-review/code-reviewer.md. Report severity-tagged issues/locations and declined-to-judge scopes.

User: nextsubtitle/APIcomments/verify/localcommit, exclude otherlongplay/weakABR. Adjacentgap chosen: extend existing oneContentEncoding from Scope1 block-only to Scope2 Private and Scope3 both. Same order0/type0/zlib/headerstripping, strictbounded inflater and runtime budgets. No dependency/native/transport changes.
Spec docs/superpowers/specs/2026-10-12-subtitle-private-compression.md; inherited plan docs/superpowers/plans/2026-09-26-remaining-02-tracks-subtitles.md; ledger .superpowers/sdd/2026-09-26-remaining-02-tracks-subtitles/progress.md latestsection.

Exact11source/test/goldenfiles andisolatedsnapshot /private/tmp/yl_private_validation.json. Production matroska_subtitles.dart behavior; comments playback_session.dart/player_controller.dart/subtitle_inflate.dart. Previous compressed_subtitle_parser_test scope2/3unsupported expectations replaced with stillunsupported5/8 without deletingcases. New private_subtitle_{test,parser_test,network_test,session_test},support/private_subtitle_fixture,fixtures/subtitle-private-owned.json.

EntryRED0/2unsupported ->69pass including blockcompression/inflate regressions. Newdirected62then67pass(43parser+7file/budget+11HTTP+6session). Pythonzlib independently compressedWEBVTTheaderandbodygoldens usedinactualfile. Test fixture initial formatting had extra parentheses, corrected before directed execution; no production defect. Mutation inisolatedsnapshot dropscompressedPrivateBytes ->two expectedbudgettestfailures, restored before final. Final fourpackages/analyze running /private/tmp/private-final-four-packages.log and private-final-analyze.log; expect1750/1750 ifno regression but do not assume before terminal.10native/buildhashunchanged.

ReviewFocus:
- _compressionScope admission defaults1 +2/3, reject0/Next/reserved/encryption/chains/WebM. MissingCodecPrivate underPrivatebit explicitlymalformed. Othercodec-privateconstraints apply afterrestoring.
- privatebytes rawbinary decoding beforeUTF8/codecvalidation, independentstreams forScope3; Scope2 Blocks untouched; Scope1 private untouched; BlockAdditional untouched.
- raw+restoredprivate each256KiB, shared4MiB checks beforeallocation, private stored chargeadded to compressionBytes retainedbyexistingruntime, WebVTT sourceBytes usesdecodedheader length not encoded. No doublecount/missingbudget for emptytracks or externalreplacement; exact counts asserted.
- matrix 7codecs x2algorithms x2scopes, nonemptyheaderstrippingbothscope, emptycodedheader, raw+decodedsize, globalprivatebudget, damage/injectedcue/nonemptySRTprivate rejection, actualfile/HTTP/runtimeatomicfailure.
- widgetfirsttrackScope3zlib andsecondScope2headerstrip, geometry/style/offset/seek/switch/off/cancellation unchanged.
- APIcomments now includeprivate/both scope; pure inflater changedcommentonly.

Prior excluded scope: Next/chains/WebM/dictionary/otheralgorithms, advancedASS/PGS/DVD, native/device/HDR/protected/externaldisplay, Period/PD03/live/manifests, RSS/GPUhardlatencyguarantees, priorMP4wvtt structuralMinor, longplay/weakABR. IndependentPythoncompression only, no independentmuxerclaim. Grade real user effect, not spec loopholes.
