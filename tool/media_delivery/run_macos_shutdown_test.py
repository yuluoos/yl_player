#!/usr/bin/env python3
"""Run real retained FlutterEngine shutdown with two live independent deliveries."""
from pathlib import Path
import argparse
import os
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tool.media_delivery.native_build import build_modules

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build-dir", type=Path, default=Path("/tmp/yl-delivery-macos-shutdown"))
args = parser.parse_args()
out = args.build_dir.resolve()
consumer = out / "consumer"
(consumer / "lib").mkdir(parents=True, exist_ok=True)
(consumer / "pubspec.yaml").write_text(
    "name: delivery_shutdown_test\nenvironment:\n  sdk: '>=3.9.0 <4.0.0'\n"
    "dependencies:\n  flutter:\n    sdk: flutter\n"
)
shutil.copyfile(Path(__file__).with_name("macos_shutdown_main.dart"), consumer / "lib/main.dart")
flutter = str(Path(os.environ["FLUTTER_ROOT"]) / "bin/flutter") if "FLUTTER_ROOT" in os.environ else "flutter"
subprocess.run([flutter, "pub", "get", "--offline"], cwd=consumer, check=True)
subprocess.run([flutter, "build", "bundle", "--debug"], cwd=consumer, check=True)
bundle = out / "ShutdownAssets.bundle"
resources = bundle / "Contents/Resources"
resources.mkdir(parents=True, exist_ok=True)
shutil.copytree(consumer / "build/flutter_assets", resources / "flutter_assets", dirs_exist_ok=True)
(bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "dev.ylplayer.shutdown-test",
    "CFBundleName": "ShutdownAssets", "CFBundlePackageType": "BNDL",
}))
build = build_modules(out / "native")
binary = build.compile_test([Path(__file__).with_name("macos_shutdown_test.swift")], out / "shutdown-test")
with subprocess.Popen(
    [sys.executable, str(ROOT / "tool/airplay/live_remux_fixture.py"), "--port", "0"],
    stdout=subprocess.PIPE, text=True,
) as fixture:
    try:
        url = fixture.stdout.readline().strip()
        if not url.startswith("http://"):
            raise RuntimeError("Live HTTP-FLV fixture failed to start")
        subprocess.run([str(binary), str(bundle), url], check=True, timeout=180)
    finally:
        fixture.terminate()
        fixture.wait(timeout=10)
