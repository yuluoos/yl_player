# Decoded layer provenance

`decoded_alignment.py` joins **actual software HEVC output** to the original
finite MP4 access units and their signalled RPU inventory. It is a research tool,
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
contract. The temporary packet files are deleted on success and failure.

Evidence records `standalone_poc_verified=true` only after every decoded frame
has a separately parsed POC and the layer association checks pass. This is the
installed FFmpeg parser's result, not an independently authored target image or
hardware-decoder certification. Its HEVC implementation assigns the public
`output_picture_number` from computed POC:
https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavcodec/hevc/parser.c

`effective_metadata_resolved=false` remains explicit. `use_previous_mapping` is
preserved and never replaced by the preceding display frame's RPU. Effective
mapping/DM inheritance and independent target generation remain separate work.
Full CM/trim/NLQ, physical DV signalling and mapping quality remain unverified
even when both layer decodes, POC and their association pass.
