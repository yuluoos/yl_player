# Decoded layer provenance

`decoded_alignment.py` joins **actual software HEVC output** to the original
finite MP4 access units and their signalled RPU inventory. Accepted homogeneous
profiles are P5/P8 single-layer and P7 with one enhancement picture per packet;
mixed profiles or enhancement NALs in a single-layer input fail. It is a research tool,
not a new player capability or a Dolby reference renderer.

Build the local probe against installed FFmpeg development libraries:

```sh
python3 -B tool/dolby_reference/probes/build_decode_probe.py --output /private/tmp/yl-decode-probe
python3 -B tool/dolby_reference/decoded_alignment.py \
  --media /absolute/path/input.mp4 --sha256 EXPECTED_MEDIA_SHA256 \
  --inspector /absolute/path/yl-dovi-stream-inspector \
  --decoder /private/tmp/yl-decode-probe/yl-decode-layers \
  --trace /absolute/path/new-decoded-trace.jsonl
```

Actual decoder integration tests are opt-in because the research probe requires
FFmpeg development headers/pkg-config modules with `AV_CODEC_FLAG_COPY_OPAQUE`
and a host FFmpeg with the `libx265` encoder (locally verified with FFmpeg 8.0.1).
Default foundation records these two tests as skipped. Enable explicitly on a
configured research host; missing/incompatible dependencies then fail visibly:

```sh
YL_RUN_DECODE_PROBE=1 python3 -B -m unittest discover -s tool/dolby_reference -p 'test_decode_probe.py'
```

The inspector is the pinned libdovi collector described in `probes/README.md`.
Media stays local; no network protocols, URLs, device state or rendering windows
are used. Existing trace paths are refused. A failed child, parse, coverage or
identity check returns exit 2 and never publishes a successful trace.

The wrapper validates finite container extents, declared sample coverage,
original file SHA-256, packet positions, unique PTS, monotonic DTS and exactly
one picture start per layer/access unit. It removes the UNSPEC63 outer header
without modifying inner EL NAL bytes. hvcC parameter sets seed the decoder;
subsequent in-band parameters remain attached to their original access unit.
The signalled RPU remains separately hashed; the software pixel decoder does
not apply RPU transforms.

Each input packet receives its original PTS/DTS and a refcounted packet index
using `AV_CODEC_FLAG_COPY_OPAQUE`. The probe drains output after each input and
at EOF. Missing tags, corrupt decoded frames, unsupported formats, duplicate or
missing output, wrong PTS and non-increasing display order fail. The join does
not assume packet order equals display order, and does not use a decoded-frame
counter as a substitute for source identity. A separate HEVC parser derives POC
from the SPS/PPS and slice state; the value travels with the packet tag through
the decoder. BL/EL POC must match for each PTS. Closed-GOP tests verify IDR POC
reset independently of monotonically increasing PTS. FFmpeg documents the general
many-to-many mapping and draining requirement; this collector accepts only the
verified one-picture/one-output subset:
https://ffmpeg.org/doxygen/trunk/group__lavc__encdec.html

Each layer's hash covers active decoded planar pixel bytes in FFmpeg's image
copy order, alignment 1, excluding row padding. Width, height, pixel format and
picture type accompany every hash. The hash is neither linear RGB/nits nor the
independent target format accepted by `pixel_compare.py`.

Limits: original/framed files 512 MiB, access unit 8 MiB, 32,768 pictures,
4096x2160 output, 64 MiB contiguous hash workspace, one software decoder thread,
32 MiB child output, 600 seconds per layer. Codec reference pictures still use
the decoder's DPB; these research limits are not a player memory admission
contract. The temporary packet files are deleted on success and failure. Executable hashes
and the build receipt identify the probe and declared FFmpeg module versions;
they do not freeze every dynamically loaded dependency or the entire host environment.

Evidence records `standalone_poc_verified=true` only after every decoded frame
has a separately parsed POC and the layer association checks pass. This is the
installed FFmpeg parser's result, not an independently authored target image or
hardware-decoder certification. Its HEVC implementation assigns the public
`output_picture_number` from computed POC:
https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavcodec/hevc/parser.c

`effective_metadata_resolved=false` remains explicit. `use_previous_mapping` is
preserved and never replaced by the preceding display frame's RPU. Effective
mapping/DM state and independent target generation remain separate work. The
optional `stream_inventory.py --mapping` mode resolves signalled mapping IDs to
coefficient records in decode order; it does not establish complete DM/trim state.
Full CM/trim/NLQ, physical DV signalling and mapping quality remain unverified
even when both layer decodes, POC and their association pass.

## 可选元数据子集来源（schema 2）

增加 `--metadata`，内部使用 schema 5 原始包盘点，把 mapping 引用、颜色头及已知 CM 块传递状态带入现有包/PTS/POC 和 BL/EL 对应核验。最终 trace 同时绑定解码像素哈希与元数据来源，并记录中间盘点 trace 哈希。默认 schema 1 不变；完整有效 DM、实际 trim/目标映射和物理 DV 仍未完成。限制和命令见 [DM_BLOCK_STATE.md](DM_BLOCK_STATE.md)。

## P8 compressed-state integration (generated fixture)

`--metadata` now also accepts P8 single-layer input. A 12-frame, 10-bit libx265
fixture exercises actual MP4 packet timestamps, B-frame reorder and closed-GOP
POC resets. A test-only FFmpeg mux helper appends four repeating RPU records
(full, compressed/use_previous, full reset, compressed/use_previous) in decode
order without altering source packet bytes. The pinned libdovi fixture is
`probes/stream_inspector/examples/cm_state_fixture.rs`; build that example in
the verified offline inspector build with `cargo build --release --locked
--offline --example cm_state_fixture` and the same manifest/environment as its
build receipt. Run integration with explicit executable paths:

```sh
YL_RUN_P8_PROVENANCE=1 \
YL_DOVI_INSPECTOR=/absolute/path/yl-dovi-stream-inspector \
YL_DOVI_CM_FIXTURE=/absolute/path/cm_state_fixture \
python3 -B -m unittest discover -s tool/dolby_reference -p 'test_p8_provenance.py' -v
```

This opt-in also requires `ffmpeg`/`ffprobe`, libx265, `cc`, `pkg-config` and
FFmpeg libavformat/libavcodec/libavutil development packages. Explicit opt-in
with missing prerequisites fails; default runs skip these three tests.
The helper is solely a generated-test fixture, not a general Dolby muxer or a
container/profile conformance validator. Generated media stays in temporary
storage. Tests compare packet timestamps, unchanged BL bytes and decoded pixel
hashes against the no-RPU source. Those pixels have no Dolby transform applied:
they verify provenance, not mapping quality or a certified P8 playback result.

The actual-video chain is now tested with **synthetic compressed metadata**;
real captured compressed/use_previous media is still missing. Compressed CM4
dynamic blocks without L254 remain unsupported by the pinned parser. Full DM,
trim/NLQ mapping, independent target generation/tolerances and physical output
remain open. Both output schemas and all qualification flags are unchanged.
