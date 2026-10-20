#!/bin/sh
# Keep the accepted self-hashed recipe and provenance byte-for-byte unchanged.
# Its optional candidate directory also lets it verify the relocated artifact.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
case "${1:---verify}" in
  --verify|--rebuild-check)
    if [ "$#" -gt 1 ]; then
      exec sh "$script_dir/build_xcframework.sh" "$@"
    fi
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/yl-media-core-artifact.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT HUP INT TERM
    ln -s "$package_root/darwin/yl_player_media_core/Frameworks/YlFFmpegBridge.xcframework" "$scratch/YlFFmpegBridge.xcframework"
    ln -s "$script_dir/bridge-artifact.lock" "$scratch/bridge-artifact.lock"
    sh "$script_dir/build_xcframework.sh" "${1:---verify}" "$scratch"
    ;;
  *) exec sh "$script_dir/build_xcframework.sh" "$@" ;;
esac
