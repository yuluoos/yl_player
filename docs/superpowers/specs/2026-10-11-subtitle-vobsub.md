# External VobSub DVD bitmap slice

P02 Task3C, user-authorized continuation. Existing opt-in and public
YlSubtitleFormat.vobsub: source is .sub, companionSource is .idx. Both are
explicit resources, independently applying their file/managed HTTP requirements;
no filename guessing, additional references or native/bridge/dependency changes.
Load index then binary under one cancellation token and 4 MiB combined catalog
input budget. Publish only a completely validated catalog; preserve old selection
on any error. Media position, offset, first-frame/seek/off/reset gates remain.

Original Dart parser for UTF-8 VobSub v7 index and MPEG-2 program-stream DVD SPU.
Index requires size and 16 RGB palette entries. id/index identifies up to32 DVD
substreams; caller language selects a unique matching primary language, otherwise
langidx (stream index) or first listed stream selects one public catalog entry.
Ambiguous/missing language fails explicitly. Timestamp/filepos maps to a pack or
PES start; index timing is authoritative, PES PTS is structural only. Delay is a
signed offset applying to subsequent entries; public offset is additional.
Neutral conventional settings are accepted; custom colors/scaling/alignment/
forced-only transformations and unknown effect settings are rejected explicitly.
No ignored effect is presented as rendered.

MPEG-2 pack/PES framing, optional PTS/DTS and bounded P-STD buffer extension,
stuffing, padding/system headers and
private_stream_1 substream IDs. Assemble fragmented packets independently per
substream; require exact declared SPU length, reject incomplete/extra data and
invalid references. MPEG-1 PS, raw SPU, HD/8-bit and compressed archives are
unsupported. All referenced entries, including unselected streams, have validated
index bounds; only selected packets are decoded into bitmaps.

DVD two-field nibble RLE supports 1..4-nibble run forms and rest-of-line fill,
byte alignment and odd heights. Commands start/forced-start/stop, palette mapping,
4-bit contrast, display rectangle and field offsets produce bounded media-time
frames, including later palette/alpha/position updates. Unknown commands and
CHG_COLCON regional effects fail explicitly. Forward linked control sequences
must terminate with a self-link; reject cycles/truncation/backward dates. One
terminal 0xff byte may align an odd-length SPU to even, as ordinary DVD producers
emit. Other trailing data, shared/overlapping RLE fields, unused PXD gaps and
multiple complete SPUs for one substream in the same pack remain unsupported.
A missing stop persists only to the next selected index entry or seven-day ceiling;
negative delayed intervals are clipped at zero. New entries replace old displays.

The existing internal PgsFrame/Bitmap slot is a shared immutable premultiplied
RGBA representation; reuse its compositor and global two-job queue, without a
second image scheduler. No GPU image is created while parsing. PGS and VobSub
share the same 64 MiB expanded catalog allowance (historical internal budget name
retained). Per bitmap <=4,194,304 pixels, canvas<=8192, SPU<=65535 bytes; input
4 MiB, index<=50,000 lines/2048 code units each, <=10,000 entries, PS<=50,000
segments, controls<=50,000 commands and <=256 sequences per SPU. Budget checks
precede RGBA/index allocation. Old/pending catalogs have separate ownership;
multiple views and engine copies are not a whole-process RSS guarantee.

Owned fixtures manually define field pixels, palette/contrast and fixed-time
rectangles. Tests cover pair I/O, managed retry/cancellation, mismatch/atomicity,
malformed PS/SPU/index, RLE, resource limits, frame timing/geometry and image
lifecycle. Real file/loopback HTTP plus fake public media events are local
acceptance, not physical-device/native/HDR/protected/embedded qualification.
No long-play or weak-network ABR workloads. Whole Task3/P02 and PD-03 stay open.

Primary format references consulted 2026-10-11 (no source/assets vendored):
- [FFmpeg n8.0 VobSub index and MPEG demuxer](https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavformat/mpeg.c)
- [FFmpeg n8.0 DVD SPU decoder](https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavcodec/dvdsubdec.c)
- [dvdauthor PES producer](https://github.com/ldo/dvdauthor/blob/master/src/subgen.c)
- [dvdauthor DVD SPU producer](https://github.com/ldo/dvdauthor/blob/master/src/subgen-encode.c)

Existing FFmpeg9.0.1 distribution hashes are rechecked against the PGS audit.
Original Dart/Flutter implementation adds no codec/library/license payload and
does not claim native DVD subtitle capability from upstream FFmpeg support.


## 2026-10-12 Matroska VobSub 扩展

此前未覆盖的 Matroska `S_VOBSUB` 已接入本地文件和 managed HTTP(S) 发现、选择与位图渲染。
CodecPrivate 全局设置及原始 SPU 使用容器时间，不请求 IDX/SUB 旁路文件；复用既有 DVD
控制/RLE/透明度解码与共享位图预算。本文原先内嵌 VobSub 的排除项由
[内嵌 VobSub 契约](2026-10-12-subtitle-embedded-vobsub.md)限定替代；高级效果、设备、
清单/直播和其他容器仍不在此范围。
