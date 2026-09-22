# Optional script resolver example

Run from this directory with `flutter run -d macos`, an iOS simulator/device,
or an Android emulator/device. Target floors: macOS12, iOS15, Android API24.

The app serves its own synthetic JavaScript and MP4 through loopback HTTP.
**Resolve & play / refresh** explicitly resolves and starts a new playback
session. **Start cancellable work** starts an infinite native JS loop; use
**Cancel & stop** to await resolver cleanup and stop playback. Each action has a
new generation, and obsolete results cannot load into the player.

This example has no subscription controller, real downstream service, RTMP
playback, or support claim for headered MP4 on Apple. The MP4 fixture is video
only; provenance and SHA-256 are in `assets/PROVENANCE.md`.

Run the public acceptance entry with:

```sh
flutter test --no-pub integration_test/script_runtime_test.dart -d DEVICE
```

The parent package README explains how authorized maintainers can generate the
ignored exact-original9 entry from the restricted archive. Never commit generated
original-containing files or share the resulting test application binaries.
