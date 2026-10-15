#!/usr/bin/env python3
"""Verify installed JNI hashes, source identity, ABI, API floor and exact exports.

Verification is read-only. --record-candidate explicitly records a newly linked
candidate; it never repairs or rewrites an installed manifest while verifying.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess

PACKAGE = Path(__file__).resolve().parents[2]
INPUTS = ["android/src/main/cpp/yl_player_ffmpeg.cpp", "android/src/main/cpp/YlSoftwareVideoBudget.inc",
          "tool/android_ffmpeg/build_shared_libraries.sh", "tool/android_ffmpeg/ffmpeg-9.0.1.lock"]
MACHINES = {"arm64-v8a": "AArch64", "armeabi-v7a": "ARM", "x86_64": "Advanced Micro Devices X86-64"}
PATTERN = r"Java_dev_ylplayer_yl_1player_1android_YlFfmpegBridge_\w+"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect(root):
    sdk = Path(os.environ.get("ANDROID_SDK_ROOT", "/opt/homebrew/share/android-commandlinetools"))
    reader = sdk / "ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf"
    if not reader.is_file():
        raise ValueError("Pinned NDK readelf is unavailable")
    exports = set(re.findall(PATTERN, (PACKAGE / INPUTS[0]).read_text()))
    libraries = {}
    for abi, machine in MACHINES.items():
        path = root / abi / "libyl_player_ffmpeg.so"
        def read(flag):
            return subprocess.check_output([str(reader), flag, str(path)], text=True)
        header, symbols, notes = read("-h"), read("--dyn-syms"), read("-n")
        if not re.search(r"Machine:\s+" + re.escape(machine) + r"\s*$", header, re.MULTILINE):
            raise ValueError(f"Wrong ELF machine for {abi}")
        if set(re.findall(PATTERN, symbols)) != exports:
            raise ValueError(f"JNI exports differ for {abi}")
        if "Android" not in notes or "description data: 18 00 00 00" not in notes:
            raise ValueError(f"Android API24 note missing for {abi}")
        libraries[abi] = {"sha256": digest(path), "minApi": 24, "jniExports": sorted(exports)}
    return {"schemaVersion": 1, "inputs": {p: digest(PACKAGE / p) for p in INPUTS},
            "configureContractSha256": digest(root / "configure-contract.txt"), "libraries": libraries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=PACKAGE / "android/src/main/jniLibs")
    parser.add_argument("--record-candidate", type=Path)
    args = parser.parse_args()
    root = args.record_candidate or args.root
    if args.record_candidate and root.resolve() == (PACKAGE / "android/src/main/jniLibs").resolve():
        parser.error("Record only a new candidate outside the installed directory")
    try:
        actual = inspect(root)
        manifest = root / "bridge-artifact.json"
        if args.record_candidate:
            if manifest.exists():
                raise ValueError("Candidate manifest already exists; do not overwrite evidence")
            manifest.write_text(json.dumps(actual, indent=2) + "\n")
        elif json.loads(manifest.read_text()) != actual:
            raise ValueError("Artifact/source/contract identity mismatch")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Android artifact verification failed: {error}\n")
    print("Android JNI artifact verified: 3 ABIs, API24, exact exports and source hashes")


if __name__ == "__main__":
    main()
