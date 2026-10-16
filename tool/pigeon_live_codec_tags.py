#!/usr/bin/env python3
"""Keep schema 3–5 factory tags stable when Pigeon hoists the schema-6 enum.

Pigeon 28 emits enums before records regardless of declaration order. Move only
this enum's tag to the first unused schema-5 tag; leave every old tag intact.
Run after Pigeon, never against hand-authored source.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parents[1]
platform = sys.argv[1]
if platform not in ('apple', 'android'):
    raise SystemExit('Expected apple or android')
base = root / 'packages' / f'yl_player_{platform}'
if platform == 'android':
    first, last = 145, 188
    native = base / 'android/src/main/kotlin/dev/ylplayer/yl_player_android/pigeon/YlPlayerAndroid.g.kt'
else:
    first, last = 146, 189
    native = base / 'darwin/yl_player_apple/Sources/yl_player_apple/Generated/YlPlayerApple.g.swift'
for path in (base / f'lib/src/pigeon/yl_player_{platform}.g.dart', native):
    source = path.read_text()
    if '// Schema-6 live enum tag relocated; legacy factory tags preserved.' in source:
        continue
    def replace(match):
        tag = int(match[2])
        tag = last if tag == first else tag - 1 if first < tag <= last else tag
        return match[1] + str(tag) + match[3]
    # Separate patterns keep unrelated numeric constants and enum raw values intact.
    for pattern in (r'(\bcase )(\d+)(:)', r'(putUint8\(|writeByte\(|stream\.write\()(\d+)(\))', r'(\s)(\d+)(\.toByte\(\) ->)'):
        source = re.sub(pattern, replace, source)
    path.write_text(source + '\n// Schema-6 live enum tag relocated; legacy factory tags preserved.\n')
