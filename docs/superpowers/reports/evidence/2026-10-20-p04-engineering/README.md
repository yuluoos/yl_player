# P04 engineering verification

Base commit: `3433d03fe04a1efebdcb1e77a5ef184d18948922`.
The final validation manifest binds changed source files and raw logs.

`protocol-smoke/` is an independent decoder check through the production relay,
using repository-owned AVC/AAC FLV and the previously pinned MediaMTX 1.21.1
archive/binary. The reproduction script validates both before executing them.
No device, player public session or physical audio/video output is implied.
HLS/FLV/RTMP FFmpeg decoders exited 0; all relays cleaned up. The HLS run has no
writes in its short middle network phase, so this run cannot establish complete
weak-network coverage. It proves real protocol transport/decoding only.
No end-to-end latency, RTT, SLO or CAP acceptance is claimed.
