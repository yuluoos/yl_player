# Fresh final review: compressed Matroska subtitles

Repo /Users/yy2021_8689/Desktop/Flutter/yl_player, base2e3c96488735f611698a4cf41e245aa70bb30952.
One read-only review; no edits, commits, subagents or Flutter execution. Follow requesting-code-review/code-reviewer.md and return severity-tagged issues with locations plus declined-to-judge scopes.

User authorizes next subtitle item, API comment repairs, verify/localcommit; avoid other longplay/weakABR. Scope: single Matroska ContentEncoding order0/type0/scope1 supporting zlib and header stripping, all already supported text/PGS/VobSub codec paths, managed reader unchanged. APIcomments create/discover. Spec docs/superpowers/specs/2026-10-12-subtitle-compression.md; approved plan docs/superpowers/plans/2026-09-26-remaining-02-tracks-subtitles.md; ledger .superpowers/sdd/2026-09-26-remaining-02-tracks-subtitles/progress.md latest section.

12 candidate files/snapshot listed in /private/tmp/yl_comp_validation.json. Production subtitles/{matroska_subtitles,subtitle_inflate,text_subtitle_runtime}.dart plus playback_session.dart,player_controller.dart. New compressed_subtitle_{test,parser_test,network_test,session_test}.dart, subtitle_inflate_test.dart,support/compressed_subtitle_fixture.dart,fixtures/subtitle-zlib-owned.json. Baseline diff is scope, exclude unrelated work.

Tests: entryRED0/2 unsupported ->74pass including oldPGS/VobSub; inflate22pass; directed78pass then85pass. Four additional invalidfixed-symbol/distance and emptyblockstorm tests now included in full run. Expected89new:37parser+5file/budget+11HTTP+6widget/session+30inflate. Snapshot budgetmutation removing retained extraInputBytes caused expected1testfail then restored. Initial11lintinfos fixed. Full/log running /private/tmp/comp-final-four-packages.log; analyzer /private/tmp/comp-final-analyze.log. Do not assume success before terminalline. Python zlib owned golden streams source formula (i*i+11*i)%251 length7000, stored/fixed/dynamic. SDK encoder multiple levels/strategies plus exactlimits/truncated prefixes/concatenated/gzip/dictionary/invalidHuffman checks. No new runtime dependency/native artifact.

Review focus:
- Strict internal RFC1950/1951 inflater: bit order, canonical Huffman, empty/single/incomplete trees, repeat codes, literal/end/reserved codes, stored complement, lengths/distance overlap/window, exact terminal position and Adler32. Every output/copy bounded before growth; perstream10000blocks. We probed SDK decoder: it accepts truncated/trailing/concatenated/gzip inputs, thus cannot alone establish strict framing.
- Matroska transformation shape/defaults: onlyone/order0/scope1/type0, alg0/3, compressionprivate/settings budgets, no WebM/encryption/chain/CodecPrivate encoding. BlockAdditional remains uncompressed per scope.
- Source encoded/settings plus restored payload counted in4MiB global budget, then persisted in runtime _Document extraInputBytes across externalreplacement/rediscovery. Exact output packet caps text64KiB/PGS256KiB/Vob65535. Existing RGBA64MiB unchanged.
- All7 codecs restore before UTF8/rawbinary decode, no timestamp/UID/selection regression. Tests include dualalgwidget geometry/style/switch/offset/seek/off and actualHTTP Range/ETag/retry/credentials/timeout/cancel/atomicfailure.
- Public APIcomments accurate without universal codec/native claim.

Inherited exclusions: compressionchains/private/nextscope, WebMcompression, otheralgorithms/dictionaries, advancedsubtitle/DVD/native/HDR/protected/externaldisplay/Period/PD03/live/manifests, priorMP4wvtt aggregateboxMinor, longplay/weakABR. This is bounded subtitle restoration, not generic archive support or RSS guarantee.
