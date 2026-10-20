#!/usr/bin/env python3
"""Compatibility entry point for the independent delivery lifecycle checks."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
subprocess.run([sys.executable, str(root / "tool/media_delivery/run_native_tests.py"),
                *sys.argv[1:]], check=True)
