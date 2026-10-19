#!/usr/bin/env python3
"""Exercise the production streaming FLV validator without network or Apple player."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
shared = root / 'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared'
with tempfile.TemporaryDirectory(prefix='yl-flv-validator-') as scratch:
    source = Path(scratch) / 'Validator.swift'
    # Isolate the actual class from AVFoundation muxing; no copied implementation.
    production = (shared / 'AirPlay/YlAirPlayLiveRemux.swift').read_text()
    source.write_text('import Foundation\nfinal class YlAirPlayFLVValidator' + production.split('final class YlAirPlayFLVValidator', 1)[1])
    output = Path(scratch) / 'test'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', '/tmp/yl-airplay-live-modules',
                    str(shared / 'FFmpeg/YlByteSource.swift'), str(source),
                    str(Path(__file__).with_name('live_remux_validator_test.swift')), '-o', str(output)], check=True)
    subprocess.run([str(output), str(root / 'tool/consumer_fixtures/apple_flutter/Resources/h264_aac.flv')], check=True)
