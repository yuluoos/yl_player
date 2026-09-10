# Diagnostics and safe failure handling

Asynchronous API failures use `YlPlayerException`, whose `failure` is an
immutable `YlFailure`. Failed authoritative playback also appears as
`state.failure` and a correlated `YlPlaybackFailedEvent`.

## Stable fields

`category` is a broad handling class: `cancelled`, `unsupported`, `source`,
`network`, `container`, `decoder`, `render`, `resource`, `protocol`, `platform`,
or `internal`.

`code` is the stable programmatic identity. Core codes are:

| Code | Meaning |
|---|---|
| `player.disposed` | The Player is terminal |
| `platform.unavailable` | No endorsed implementation is available |
| `platform.incompatible` | The implementation does not implement SPI major 2 |
| `load.cancelled` | A newer operation cancelled the pending Load |
| `session.stale` | A replaced/stopped Session handle was used |
| `policy.unsupported` | The selected route cannot enforce a requested policy |
| `source.invalid` / `source.missing` | Invalid source metadata or unavailable local source |
| `network.failed` | Managed or platform network operation failed |
| `container.unsupported` | No supported container route |
| `decoder.unsupported` / `decoder.unavailable` | Unsupported media or unavailable required decoder |
| `resource.exhausted` | A bounded native resource could not be acquired |
| `protocol.mismatch` | Native/Dart state or transport violated the SPI contract |
| `platform.failure` / `internal.failure` | Safe fallback identities for platform/internal faults |

Platforms may add validated extension codes. Treat unknown codes within a known
category conservatively.

`scope` says what authority failed: `command` leaves broader state unchanged,
`session` terminates or rejects one session, and `player` makes the Player
unusable. `retryable` is a property of that failure, not permission to bypass
the configured retry budget or repeat a non-idempotent application action.

`message` is safe user-facing text supplied at the public boundary. Native
adapters replace untrusted native text with a generic message. Applications may
display it, but should branch on category/code rather than wording.

`diagnosticId` is an opaque correlation token. Include it with code, category,
scope, app build, package version, platform/OS version, and a local timestamp in
support logs. The ID is useful only when matched to protected implementation
logs from the same run; it is not a source locator or globally unique incident
number.

```dart
try {
  await session.play();
} on YlPlayerException catch (error) {
  final failure = error.failure;
  logger.warning(
    'playback code=${failure.code} category=${failure.category.name} '
    'scope=${failure.scope.name} diagnostic=${failure.diagnosticId}',
  );
}
```

Never log or attach source URIs/paths, query strings, ordinary request headers,
credentials, cookies, tokens, decoder identities, native error strings, native
stacks, proxy configuration, or media payload bytes. Do not stringify arbitrary
caught objects: use the `YlFailure` fields or a static fallback message.

There is no public method that exposes raw native diagnostics. Do not document
or depend on implementation methods, Pigeon messages, platform channels, or
private native logs as an application API. `toString()` redacts sensitive model
fields and unsafe metadata, but explicit safe-field logging remains preferred.
