# Decoded EOF resource length matrix

Base: the independent finite-file EOF protocol. Generate 4, 30 and 60 second
controls by stream-copying the same prefix of the existing owned 1260s AVC/AAC
fixture (320x180, 24fps; 48kHz stereo AAC). No re-encoding or repeated playback.
Preserve ffmpeg command/version, source and derived hashes, ffprobe stream/packet
counts and format durations. Generated files are build artifacts, not new public
media assets. Freeze all three files and manifest for every arm.

Run 4s legacy, 4s candidate, 30s legacy, 30s candidate, 60s legacy, 60s candidate
sequentially in six independent processes using the same source/binary identity.
No build, parallel benchmark or source/tool edit during these runs. Retain failed
attempts. Use the existing 8s heap, 30s ACK, 180s test and 240s parent deadlines.
The natural completion wait is selected duration +10s, within the test deadline;
this replaces the former 10s wait specific to the original 4.021s fixture.

Only configured/drained/disposed request heap; completed is observation only and
precedes the test's pause of native audio. Preserve disposedLater >=2s. Keep exact
PID, complete heap table, native callback, single completion/first frame, no error,
no candidate fallback and close release checks from the original protocol.
Record elapsed playback from immediately before play to observed completed,
excluding heap/ACK time; accept requested duration -.5s through duration +10s.
The collector must verify selected fixture name and measured playback duration.

Do not retain progress-event history: count deltas and discard their payloads and
the recorder's order log on acknowledgement. Before each snapshot, yield until
in-flight acknowledgements have cleared both arrays (5s deadline, throw/close on
timeout); then read the snapshot without another await. This wait is outside the
recorded playback elapsed interval. Validate both arrays empty and at
most 32 retained infrequent public events. The three PCM prefix records and native
failure diagnostics remain capped by existing probes. Report actual submission
counts. For each length, both arms must submit the same count; 30s must exceed 4s
by >5x and 60s must exceed 30s by >1.8x. These cross-length checks reject accidentally
replaying the short control. No synthetic frame-marker claim is made.

Report per-arm configured/drained/disposed heap totals and their deltas, allocation
counts, RSS/footprint, managed ledger and actual callback counts. No post-hoc
numerical pass threshold for process heap growth: all valid observations, including
increases, must be retained and discussed. One sample per arm/length only supports
an exploratory post-EOF trend. It does not prove a live resource bound, asymptotic
bound, statistical improvement, physical output or device-switch recovery.
Keep defaultEnabled, productionAdmission and downstreamBoundProven false.
