#!/usr/bin/env python3
"""Generate an ignored complete device entry; print IDs/hashes only, never download.

Use --remove after acceptance. The restricted original source archive is preserved.
"""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import re
import subprocess

PACKAGE = Path(__file__).resolve().parents[1]
TARGET = PACKAGE / 'example/integration_test/generated/controlled_runtime_test.dart'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--remove', action='store_true')
    args = parser.parse_args()
    if args.remove:
        TARGET.unlink(missing_ok=True)
        return
    if args.archive is None:
        parser.error('--archive is required')
    ignored = subprocess.run(['git', 'check-ignore', '-q', str(TARGET)], cwd=PACKAGE)
    if ignored.returncode != 0:
        raise SystemExit('Refusing to write a non-ignored original-source fixture')
    contract = (PACKAGE / 'test/support/controlled_contract.dart').read_text()
    entries = re.findall(r"'(JS-\d+)': \(\s*'([^']+)',\s*'[^']+',\s*'([0-9a-f]{64})',", contract)
    if len(entries) != 9:
        raise SystemExit('Expected exactly nine frozen manifest entries')
    encoded = {}
    for script_id, filename, expected in entries:
        raw = (args.archive / filename).read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if digest != expected:
            raise SystemExit(f'{script_id}: original-byte digest mismatch')
        raw.decode('utf-8', errors='strict')
        encoded[script_id] = base64.b64encode(raw).decode('ascii')
        print(f'{script_id} SHA256 {digest}')
    source = "import 'package:integration_test/integration_test.dart';\nimport '../../../test/support/controlled_contract.dart';\nimport '../script_runtime_test.dart' as runtime;\n\nvoid main() {\n  IntegrationTestWidgetsFlutterBinding.ensureInitialized();\n  runtime.registerRuntimeContracts();\n  registerControlledContracts({\n"
    source += ''.join(f"    '{key}': '{value}',\n" for key, value in encoded.items())
    source += '  });\n}\n'
    TARGET.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(TARGET.parent, 0o700)
    fd = os.open(TARGET, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as output:
            output.write(source)
    except BaseException:
        TARGET.unlink(missing_ok=True)
        raise
    print('Generated complete ignored integration entry; remove after use.')


if __name__ == '__main__':
    main()
