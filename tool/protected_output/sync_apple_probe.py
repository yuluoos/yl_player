#!/usr/bin/env python3
"""Keep the isolated Debug probe embedded in the existing example runner files."""
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[2]
BEGIN = '// BEGIN GENERATED PROTECTED VIEW PROBE\n'
END = '// END GENERATED PROTECTED VIEW PROBE\n'
source = (ROOT/'tool/protected_output/AppleProtectedViewProbe.swift').read_text()
for name in ['ios/Runner/AppDelegate.swift', 'macos/Runner/MainFlutterWindow.swift']:
    path = ROOT/'packages/yl_player/example'/name
    old = path.read_text()
    if BEGIN in old:
        assert old.count(BEGIN) == 1 and old.endswith(END), f'Unexpected generated block boundary: {name}'
    prefix = old.split(BEGIN)[0].rstrip() + '\n\n'
    expected = prefix + BEGIN + source + END
    if '--check' in sys.argv:
        assert old == expected, f'Probe copy differs: {name}'
    else:
        path.write_text(expected)
