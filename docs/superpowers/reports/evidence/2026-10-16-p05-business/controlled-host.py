#!/usr/bin/env python3
"""Reproduce the frozen host contracts privately; never prints source bytes.

Usage: python3 controlled-host.py --player <repo> --archive <private archive>
       --flutter <SDK/bin/flutter>
Requires the already resolved package config and current frozen manifest.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--player', type=Path, required=True)
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--flutter', type=Path, required=True)
args = parser.parse_args()
package = args.player.resolve() / 'packages/yl_player_source_resolver'
spec = importlib.util.spec_from_file_location(
    'controlled_archive', package / 'tool/generate_controlled_integration.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
receipt, encoded = module.verify_archive(args.archive)
print(json.dumps(receipt), flush=True)
if receipt['status'] != 'verified':
    raise SystemExit(1)
with tempfile.TemporaryDirectory(prefix='.p05-controlled-', dir=package / 'test') as directory:
    target = Path(directory) / 'controlled_test.dart'
    with target.open('x') as stream:
        os.chmod(target, 0o600)
        stream.write("import '../support/controlled_contract.dart';\n")
        stream.write('void main() { registerControlledContracts(')
        stream.write(json.dumps(encoded))
        stream.write('); }\n')
    result = subprocess.run([str(args.flutter.resolve()), 'test', '--no-pub',
                             '--concurrency=1', str(target)], cwd=package)
    raise SystemExit(result.returncode)
