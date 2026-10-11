# Managed HTTP for external subtitles

This extends the opt-in Dart SRT/WebVTT runtime from 8ab86d0 using the existing
`YlNetworkPolicy.managed` contract. No native wire/API, playback network tools,
long-play code or media ABR policy changes are needed.

- Connect timeout is per hop, from DNS/TCP/TLS through response headers.
- Body timeout is inactivity after headers, reset only by nonempty chunks.
  Managed mode has no total-call deadline; platformDefault retains its 30s total,
  five redirects and zero retries. File reads retain their existing deadline.
- GET retries transient socket/timeout failures and premature HTTP connection
  closure, or status 408/429/500/502/503/504. Cancellation, validation, TLS errors,
  permanent HTTP failures, unsupported encodings and size/parse failures do not
  retry. An owned socket observer preserves original transport error types before
  HttpClient wraps header-phase errors, including TCP reset. Each retry starts a
  fresh connection and empty bounded body buffer.
- maxRetries excludes the initial attempt. Exponential delay saturates at
  maxRetryDelay without jitter or unbounded arithmetic. Valid Retry-After seconds
  or HTTP dates override the formula only when within maxRetryDelay; an excessive
  valid value stops retrying. Malformed values use the formula; past dates mean
  zero wait. Date arithmetic is tested against an injected wall-time value;
  scheduling uses Dart timers, not wall-clock polling.
- Retry resumes the current URI. One maxRedirects counter spans the whole
  resource operation. Credentials are stripped permanently after an origin
  change, including return hops and retries. HTTPS downgrade is rejected.
- Every attempt and backoff wait is cancellable. Timeout closes owned sockets,
  including stalled TLS handshakes. Late completions cannot publish a result or
  release the next attempt's resources. Timer/subscription ownership is bounded.
- Existing aggregate subtitle byte/cue/span budgets and atomic catalog commit
  remain authoritative. Truncated attempt bytes never enter a later document.
  Terminal errors remain sanitized, non-retryable command failures after the
  managed retry budget is exhausted; no additional outer retry is requested.

Validation: real loopback HTTP, raw sockets/TLS fixtures, deterministic retry
formula/date tests, public session replacement/cancellation and existing package
regression. This is not weak-network ABR or physical-device playback evidence.

HTTP date syntax follows [RFC 9110 §5.6.7](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.7)
and Retry-After follows [§10.2.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3).
The local SDK's permissive date normalization is not used for policy admission.
The three date forms are checked against real calendar fields, with RFC850's
50-year future window computed from the injected clock, including century edges.

Cancellation completion may precede a pending Stop ACK and reports load.cancelled;
commands after the accepted Stop remain session.stale. Tests hold the Stop reply
explicitly to verify both phases without relying on microtask timing.
