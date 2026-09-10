# Apple platform policy support

The shared Apple package targets iOS 15+ and macOS 12+. Native compilation and selected simulator/macOS checks during implementation are recorded in the Hardening task reports; they do not substitute for the final device, architecture, integration and independent-consumer matrices.

| Route | platformDefault | Managed networking |
| --- | --- | --- |
| Network Matroska | Owned byte source; codec inspection required | Owned deadlines, retries, redirect budget and credential filtering |
| Network FLV | Owned sequential byte source; codec inspection required | Owned policy, including retries before body consumption |
| HLS | AVPlayer; metadata uses controlled manifest/key loader and credential-bearing media proxy | `policy.unsupported` before known-format upstream open |
| MP4 / MOV | AVPlayer; HTTP metadata rejected where controlled routing is unavailable | `policy.unsupported` before upstream open |
| AVI / MPEG TS / MPEG PS | Unsupported by the pinned fallback demuxer artifact | `policy.unsupported` before upstream open |
| Unknown network format | Package-owned inspection, capped at 4096 signature bytes | Inspection uses the same managed options and original request intent before reassessment |

WebM and local FLV remain staged. Bounded buffering and hardware-required production availability remain disabled pending their owning tasks. AVPlayer reports decoder mode unknown and exposes no exact managed network guarantee. This task does not expand the FFmpeg demuxer artifact or its build recipe. See [policy semantics](policies.md).

Managed HTTP uses the constrained HTTP/1.1 transport described in [policy semantics](policies.md), including explicit proxy/PAC, framing, encoding and app transport-security rejection. Selected local TLS tests use disposable identities imported only into memory and an isolated normal SSL trust evaluation with a fixed fixture date; they establish encrypted transfer, chain/hostname checks and non-retryable rejection. Production system-trust success against a publicly trusted server remains a final acceptance evidence item. The isolated PKCS12 server fixture requires macOS15+; older macOS skips that fixture before importing any identity. Production minimum versions remain unchanged.
