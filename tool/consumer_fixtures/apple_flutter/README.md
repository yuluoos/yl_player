# Independent Apple Flutter consumers

These templates generate four separate applications using the installed Flutter
SDK. Their only plugin is the active checkout's `yl_player_apple`, with a direct
path override for `yl_player_platform_interface`. Native plugin code and the
FFmpeg artifact are consumed through Flutter's generated dependency graph.

Run from the active checkout:

```sh
export YL_REPO_ROOT=$(git rev-parse --show-toplevel)
export YL_FLUTTER=/path/to/flutter/bin/flutter
export YL_APPLE_CONSUMERS=/private/tmp/my-apple-consumers
export YL_IOS_SIMULATOR=available-iphone-simulator-uuid
sh tool/bootstrap_apple_consumers.sh
sh tool/check_apple_consumer.sh --platform macos --manager swiftpm --unit-only
sh tool/check_apple_consumer.sh --platform ios --manager swiftpm --unit-only
sh tool/check_apple_consumer.sh --platform ios --manager cocoapods --unit-only
sh tool/check_apple_consumer.sh --platform macos --manager cocoapods --unit-only
```

Capture `YL_REPO_ROOT` before leaving the checkout. Both entry points accept it
from a caller in another directory and reject a root that does not match their
own checkout. Generated apps, pub caches, Xcode derived data, package caches and
result bundles stay outside the repository. `YL_APPLE_LOG_DIR` optionally sets
the evidence directory; its default is the temporary consumer root's `logs`.
Every subprocess receives the root, and every command records its directory,
output and exit code. Native operations run serially. No global Flutter feature
settings are changed: each generated pubspec selects its package manager.

`--unit-only` compiles and runs the native characterization suites in a real
Flutter application. It also verifies the built app/test deployment floors,
engine/bridge linkage, embedding and runtime search paths. `--link` builds and
checks the ordinary Debug application without running the unit suite. The iOS
destination is an available simulator; these gates do not claim device/release
archive coverage. `--platform` and `--manager` can limit bootstrap to one host.
An interrupted bootstrap can resume only when its ownership marker identifies
the same checkout. Choose a new consumer root after changing fixture templates.

The engine matrices contain 217 iOS cases and 166 macOS cases. They exercise
all migrated shared engine algorithms and platform compatibility branches,
including the original 81 neutral cases. `tests-manifest.json` records those
neutral suites; `engine-tests-manifest.json` maps the remaining original suites,
method identities, fixture hashes and narrowly transferred host cases.
`new-tests-manifest.json` records boundary regressions and constructor-only native
fixture glue. The nine media resources retain their original bytes and provenance
in `resources-manifest.json`. Production code is built through the plugin; tests
never embed copied playback implementations or a substitute Flutter framework.

Only the two existing iOS hardware skips named in `allowed-hardware-skips.json`
are allowed. The gate checks every native class/method identity and skip name,
in addition to counts. Exactly 20 legacy host methods (11 iOS, 9 macOS) require
the Task 7 typed player host; `task7-host-cases.json` preserves each original
body and maps its assertions to the required typed-host counterpart. No other
methods from mixed suites are deferred. These are complete engine matrices;
complete player parity additionally requires those host cases and four complete
consumer matrices before endorsement.

Platform services own SDK bindings. The player host owns texture registration
and final disposal; engines borrow the output across sessions. Boundary tests
cover Stop cache clearing, retired backend output authority, lifecycle observer
removal and weak macOS display-view binding. Platform policy tests preserve the
existing scheduler, audio, recovery and VideoToolbox differences.

The project requires Python 3.9+, Ruby with `xcodeproj`, CocoaPods, Flutter and
Xcode for native gates. Normal Dart tests do not invoke these Apple tools. The
source-parity negative tests are portable:

```sh
python3 -B -m unittest discover -s tool/consumer_fixtures/apple_flutter -p 'test_*.py'
```
