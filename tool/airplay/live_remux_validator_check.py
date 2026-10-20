#!/usr/bin/env python3
"""Exercise the real delivery module's streaming FLV validator."""
from pathlib import Path
import subprocess
import sys

subprocess.run([sys.executable, str(Path(__file__).with_name("run_module_tests.py")),
                "validator", *sys.argv[1:]], check=True)
