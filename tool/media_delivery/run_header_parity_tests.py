#!/usr/bin/env python3
"""Compile actual native entry points and verify their request metadata policy."""
from pathlib import Path
import argparse
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tool.media_delivery.native_build import build_modules

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build-dir", type=Path)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="yl-header-parity-") as scratch:
    directory = args.build_dir or Path(scratch)
    build = build_modules(directory, include_apple=True)
    binary = build.compile_test([Path(__file__).with_name("header_parity_test.swift")],
                               directory / "header-parity")
    subprocess.run([str(binary)], check=True)
