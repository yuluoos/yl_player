#!/usr/bin/env python3
"""单独编译 core 与 delivery；交付测试不编译或链接 Apple 播放器。"""
from pathlib import Path
import argparse
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tool.media_delivery.native_build import build_modules

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("url", nargs="?", help="可选 HTTP-FLV/RTMP(S) 测试源")
parser.add_argument("--build-dir", type=Path, default=Path("/tmp/yl-delivery-native-modules"))
args = parser.parse_args()
build = build_modules(args.build_dir)
binary = build.compile_test([Path(__file__).with_name("standalone_test.swift")],
                           args.build_dir / "standalone-tests")
subprocess.run([str(binary), *([args.url] if args.url else [])], check=True)
dependencies = subprocess.check_output(["otool", "-L", str(binary)], text=True)
if "libyl_player_apple" in dependencies:
    raise RuntimeError("Standalone delivery unexpectedly links the player")
print("PASS standalone delivery has no Apple player binary dependency")
