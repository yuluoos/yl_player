#!/bin/sh
set -eu
app=${1:?usage: build.sh NEW_DIRECTORY/Marker.app}
test ! -e "$app"
mkdir -p "$app/Contents/MacOS"
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
xcrun swiftc -O "$source_dir/main.swift" -o "$app/Contents/MacOS/Marker"
codesign --force --sign - "$app"
