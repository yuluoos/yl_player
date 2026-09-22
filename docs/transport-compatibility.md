# Dart/native transport compatibility

The DASH format addition uses private Android/Apple transport schema **3**.
The public Dart platform SPI remains **2**. Existing media-format enum wire
values 0–9 are unchanged; DASH is appended at value 10.

Appending an enum value does not make a new client safe against an older native
decoder: schema 2 has no representation for value 10 and no format-feature
negotiation. Create therefore checks the private schema before source messages
or native playback resources are accepted. A schema mismatch is rejected using
the existing platform/protocol incompatibility failure, rather than allowing an
unknown enum into a running session.

Update the Dart adapter and its native plugin together and rebuild the host app.
A hot reload into an old native binary is insufficient. Schema 2/3 combinations
are deliberately incompatible even when the caller plans to play an older
format; matching schema 3 retains the existing public Player/Session behavior.
The private generated channels are not consumer APIs.

Both adapters reject a schema 2 Create reply and release any returned native
identity. Both native registries reject schema 2 requests before allocating a
texture/session. Regression tests also retain the older schema 1 rejection and
the public SPI mismatch checks.

Apple routes an inspected, bounded subset of clear static DASH through its
private HLS adapter. Protocol recognition alone does not establish playback
support for every MPD; use `assess` and consult the
[platform support matrix](platform-support.md).

The optional `yl_player_source_resolver` package uses its own private native FFI
runtime and does not alter this schema or the public platform SPI. Applications
explicitly convert a successful HTTP(S) resolution into an existing
`YlNetworkSource`; installing the resolver does not add media protocols to the
player.
