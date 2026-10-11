# Network Matroska embedded subtitles

Continue the approved P02 embedded route and managed transport contract. The
public command remains `session.discoverEmbeddedSubtitles()` under
`enableTextSubtitles: true`. This extension supports committed HTTP(S) Matroska
sources with automatic/on-demand intent, no DRM, automatic/Matroska format.
Existing UTF8/SRT, ASS/SSA parsing, selection, offsets, rendering and atomic
external/embedded catalog semantics remain unchanged. No new native bridge,
dependency, binary or operation ordinal is added.

## Range and identity contract

Use single HTTP GET byte ranges with `Accept-Encoding: identity`; do not fetch a
whole media body when the server ignores Range. Require 206, exact single
Content-Range with a known positive total <=2^53-1 and a syntactically valid
strong ETag <=1024 code units. Clamp only the requested end at EOF. Require exact
body size and Content-Length consistency when supplied. Chunked 206 is allowed
only with the same exact range/body checks. Reject multipart and compressed
representations, missing/weak validators, malformed ranges and full-body 200.

The first complete window pins URI, total and ETag. Later windows send If-Match
and verify the same ETag/total. A 412 or changed metadata rejects the candidate;
a redirect after pinning is also rejected because ETags are resource scoped.
Redirects before pinning follow the existing managed policy. A new discovery
starts a fresh snapshot and may select a new representation atomically.
This establishes consistency among subtitle range reads; it cannot prove that
the native video's independent HTTP request used the same representation.
Caller conditional headers (If-Match/If-Range/If-None-Match/If-Modified-Since/
If-Unmodified-Since) conflict with reader ownership and fail before I/O. Caller
Accept-Encoding must be identity. Existing request metadata validation applies.

## Managed transport and budgets

Reuse the existing subtitle HTTP attempt implementation: per-hop connect/header
deadline, body-inactivity deadline reset on progress, bounded transient GET
retries and Retry-After, TLS certificate validation, HTTPS downgrade rejection,
and origin-scoped credentials. One resource ledger spans all windows, redirects
and retries in a discovery. Counts never reset per window. Credentials stripped
after an origin change stay stripped for retries and subsequent windows.
Managed scans have no total wall-clock deadline. platformDefault uses the
existing 30-second total timeout, five redirects and no retries.

Each attempt owns its client/socket/partial body and cancellation listener;
no connection pooling can replay requests outside the ledger. Keep <=128
16-KiB windows (2 MiB LRU), <=4096 HTTP attempts including redirects/retries, and
<=64 MiB accepted body progress across attempts. A demux read may span windows
up to the existing 256-KiB CodecPrivate limit. All Matroska parser and subtitle
catalog budgets remain in force. These limits are resource caps, not a promise
that arbitrarily large movies can be scanned. Dense media may hit the network
budget; skipping large payload elements does not mean every file needs few GETs.
No sparse-index acceleration, streaming/live Matroska or full-download fallback.

Cancellation from replacement, Stop, Dispose or another catalog command aborts
active transport/backoff and prevents late publication. Failure keeps prior
subtitle catalog/selection and does not independently fail video (PD-03 open).
Diagnostics carry safe codes/categories/scopes and never URI, credentials, ETag
or server text. Network scan errors are sanitized at the embedded I/O boundary.

## Verification and open scope

Owned loopback HTTP ranges cover real demux input, sparse reads, mixed versions,
credential origin changes, status retries, redirect/retry budgets, partial-body
and header deadlines, progress, cache eviction, request limits and cancellation.
Owned TLS fixtures verify certificate rejection, HTTPS success and downgrade
rejection; the test-file VM trusts an owned certificate only in its success test.
Public session/widget tests use real network subtitle data and fake video state.
No native/device playback, long-play or weak-network ABR workloads run.

MP4/HLS/DASH/WebM/content URI, encrypted/compressed/unsupported Matroska subtitle
codecs, native subtitle callbacks, HDR/protected output and full P02/CAP-SUB
qualification remain open. Servers without single-range 206 and stable strong
ETags are explicitly outside this route. Existing external managed subtitles and
local embedded behavior must remain covered by the full regression suite.

Reference: RFC 9110 sections 8.8.3, 13.1.1, 14 and 15.3.7:
https://www.rfc-editor.org/rfc/rfc9110.html . No source code or media copied.
