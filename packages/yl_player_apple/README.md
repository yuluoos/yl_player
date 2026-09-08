# yl_player_apple

Shared iOS and macOS implementation package for `yl_player`.

This development package currently contains the federated registration and
Apple packaging skeleton. Player creation deliberately reports
`platform.unavailable` until the typed native registry is connected.

The package targets iOS 15.0 and macOS 12.0. Applications should depend on
`yl_player`; Flutter will select this implementation after it is endorsed by
the app-facing package.
