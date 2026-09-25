# Dart/native transport compatibility

The DASH format addition used private Android and Apple transport schema **3**.
Android fixed-video selection now uses private schema **4**; Apple remains at
schema **3**. The public Dart platform SPI remains **2**. Existing media-format
enum wire values 0–9 are unchanged; DASH is appended at value 10.

Appending an enum value does not make a new client safe against an older native
decoder: schema 2 has no representation for value 10 and no format-feature
negotiation. Create therefore checks the private schema before source messages
or native playback resources are accepted. A schema mismatch is rejected using
the existing platform/protocol incompatibility failure, rather than allowing an
unknown enum into a running session.

Update the Dart adapter and its native plugin together and rebuild the host app.
A hot reload into an old native binary is insufficient. Android schema 3/4
combinations are deliberately incompatible even when the caller plans to play
an older format; matching schema 4 adds nullable fixed-video commands and
selection state. Apple schema 2/3 combinations remain incompatible, and
matching schema 3 retains the existing Apple Player/Session behavior. The
private generated channels are not consumer APIs.

Android's schema-4 Pigeon additions follow the schema-3 message classes. In
particular, factory codec tags for `AndroidPlayerOptionsMessage`,
`AndroidCreateRequest`, and `AndroidCreateReply` remain 145, 146, and 147.
Captured factory requests encoded by the committed schema-3 codec still decode
under the schema-4 codec and reach the native version check, which rejects them
as `platform.incompatible` before allocating a texture or session. A schema-4
request likewise reaches an old schema-3 factory decoder with the same factory
tags and is rejected on its version check. This preserves a controlled version
failure rather than a codec cast failure before negotiation.

Both adapters reject a schema 2 Create reply and release any returned native
identity. Both native registries reject schema 2 requests before allocating a
texture/session. Android additionally rejects schema 3 requests and replies;
Apple continues to use schema 3. Regression tests retain the older schema 1
rejection and the public SPI mismatch checks.

Apple routes an inspected, bounded subset of clear static DASH through its
private HLS adapter. Protocol recognition alone does not establish playback
support for every MPD; use `assess` and consult the
[platform support matrix](platform-support.md).

The optional `yl_player_source_resolver` package uses its own private native FFI
runtime and does not alter this schema or the public platform SPI. Applications
explicitly convert a successful HTTP(S) resolution into an existing
`YlNetworkSource`; installing the resolver does not add media protocols to the
player.
