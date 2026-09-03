# yl_player_android

Endorsed Android implementation package for `yl_player`.

Version `0.1.0-dev.1` provides federated Dart/native registration and an
idempotent compile-safe placeholder player. It targets Android 7.0 (API 24) or
later, but Media3 playback is **not implemented in this milestone**. Every
playback command fails with the structured code `android.not_implemented`.

Applications should depend on `yl_player`; Flutter selects this package on
Android automatically.
