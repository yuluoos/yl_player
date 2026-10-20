#!/usr/bin/env python3
"""Build core/delivery once, then exercise real remux, store, validator and queue."""
from pathlib import Path
import argparse
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tool.media_delivery.native_build import build_modules


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checks", nargs="*", metavar="CHECK", help="vod, store, validator, queue (default: all)")
    parser.add_argument("--build-dir", type=Path, default=Path("/tmp/yl-airplay-native-modules"))
    parser.add_argument("--live-fixture", action="store_true", help="Also decode live HLS from a local HTTP-FLV fixture")
    args = parser.parse_args()
    checks = args.checks or ["vod", "store", "validator", "queue"]
    if set(checks) - {"vod", "store", "validator", "queue"}:
        parser.error("Unknown check; choose vod, store, validator, or queue")
    build = build_modules(args.build_dir)
    folder = Path(__file__).parent
    fixtures = ROOT / "tool/consumer_fixtures/apple_flutter/Resources"
    sources = {"vod": "remux_test.swift", "store": "live_store_tests.swift",
               "validator": "live_remux_validator_test.swift", "queue": "media_delivery_test.swift"}
    for name in checks:
        binary = build.compile_test([folder / sources[name]], args.build_dir / f"{name}-tests")
        arguments = [str(fixtures)] if name == "vod" else ([str(fixtures / "h264_aac.flv")] if name == "validator" else [])
        subprocess.run([str(binary), *arguments], check=True)
        dependencies = subprocess.check_output(["otool", "-L", str(binary)], text=True)
        if "libyl_player_apple" in dependencies:
            raise RuntimeError(f"{name} unexpectedly links the Apple player")
    if args.live_fixture:
        binary = build.compile_test([folder / "live_remux_test.swift"], args.build_dir / "live-tests")
        fixture = subprocess.Popen([sys.executable, str(folder / "live_remux_fixture.py"), "--port", "0"],
                                   stdout=subprocess.PIPE, text=True)
        try:
            url = fixture.stdout.readline().strip()
            if not url.startswith("http://127.0.0.1:"):
                raise RuntimeError("Local HTTP-FLV fixture did not start")
            subprocess.run([str(binary), url], check=True, timeout=90)
        finally:
            fixture.terminate()
            fixture.wait(timeout=10)
    print("PASS AirPlay checks use independent core/delivery modules")


if __name__ == "__main__":
    main()
