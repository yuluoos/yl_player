#!/usr/bin/env python3
"""Verify a restricted archive offline, or generate an ignored device entry.

No downloads or script execution. Output contains fixed IDs, hashes and statuses.
Use --remove after device acceptance; the source archive remains unchanged.
"""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys

PACKAGE = Path(__file__).resolve().parents[1]
TARGET = PACKAGE / 'example/integration_test/generated/controlled_runtime_test.dart'
MAX_SCRIPT_BYTES = 512 * 1024


class ArchiveError(Exception):
    """Messages are fixed diagnostics, never exception text from private input."""


def manifest():
    raw = (PACKAGE / 'test/support/controlled_contract.dart').read_bytes()
    contract = raw.decode('utf-8')
    entries = re.findall(r"'(JS-\d+)': \(\s*'([^']+)',\s*'[^']+',\s*'([0-9a-f]{64})',", contract)
    if (len(entries) != 9 or sorted(row[0] for row in entries) !=
            [f'JS-{n:02}' for n in range(1, 10)] or
            len({row[1] for row in entries}) != 9 or
            any(not re.fullmatch(r'[A-Za-z0-9_-]+\.js', row[1]) for row in entries)):
        raise ArchiveError('Invalid frozen nine-script manifest')
    return sorted(entries), hashlib.sha256(raw).hexdigest()


def read_script(directory, filename, expected):
    """No link following or blocking on a FIFO; read at most the source limit + 1."""
    try:
        fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                     dir_fd=directory)
    except FileNotFoundError:
        return {'status': 'missing'}, None
    except OSError:
        return {'status': 'not_regular' if stat.S_ISLNK(
            os.stat(filename, dir_fd=directory, follow_symlinks=False).st_mode)
                else 'unreadable'}, None
    with os.fdopen(fd, 'rb') as source:
        metadata = os.fstat(source.fileno())
        if not stat.S_ISREG(metadata.st_mode):
            return {'status': 'not_regular'}, None
        if metadata.st_mode & 0o077:
            return {'status': 'not_private'}, None
        if metadata.st_size > MAX_SCRIPT_BYTES:
            return {'status': 'too_large'}, None
        raw = source.read(MAX_SCRIPT_BYTES + 1)
    if len(raw) > MAX_SCRIPT_BYTES:
        return {'status': 'too_large'}, None
    row = {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
    if row['sha256'] != expected:
        return dict(row, status='digest_mismatch'), None
    try:
        raw.decode('utf-8', errors='strict')
    except UnicodeDecodeError:
        return dict(row, status='invalid_utf8'), None
    return dict(row, status='verified'), raw


def verify_archive(archive):
    entries, contract_hash = manifest()
    report = dict(schemaVersion=1, status='failed', executed=False,
                  contractSha256=contract_hash, archiveStatus='verified', scripts=[])
    encoded = {}
    directory = None
    try:
        directory = os.open(archive, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        if os.fstat(directory).st_mode & 0o077:
            report['archiveStatus'] = 'not_private'
    except OSError:
        report['archiveStatus'] = 'unavailable'
    try:
        for script_id, filename, expected in entries:
            if report['archiveStatus'] != 'verified':
                row, raw = {'status': 'archive_unavailable'}, None
            else:
                try:
                    row, raw = read_script(directory, filename, expected)
                except OSError:
                    row, raw = {'status': 'unreadable'}, None
            report['scripts'].append(dict(id=script_id, expectedSha256=expected, **row))
            if raw is not None:
                encoded[script_id] = base64.b64encode(raw).decode('ascii')
    finally:
        if directory is not None:
            os.close(directory)
    if len(encoded) == 9:
        report['status'] = 'verified'
    return report, encoded


def check_ignored():
    result = subprocess.run(['git', 'check-ignore', '-q', str(TARGET)], cwd=PACKAGE,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode != 0:
        raise ArchiveError('Refusing a tracked or non-ignored original-source fixture')


@contextmanager
def output_directory(create):
    """Pin each directory descriptor; neither generation nor removal follows links."""
    relative = TARGET.relative_to(PACKAGE)
    directory = os.open(PACKAGE, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in relative.parts[:-1]:
            if create:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=directory)
                except FileExistsError:
                    pass
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=directory)
            except FileNotFoundError:
                if not create:
                    yield None
                    return
                raise
            os.close(directory)
            directory = child
        if create:
            os.fchmod(directory, 0o700)
        try:
            mode = os.stat(TARGET.name, dir_fd=directory, follow_symlinks=False).st_mode
            if not stat.S_ISREG(mode):
                raise ArchiveError('Refusing a non-regular output fixture')
        except FileNotFoundError:
            pass
        yield directory
    finally:
        os.close(directory)


def generate(encoded):
    source = "import 'package:integration_test/integration_test.dart';\nimport '../../../test/support/controlled_contract.dart';\nimport '../script_runtime_test.dart' as runtime;\n\nvoid main() {\n  IntegrationTestWidgetsFlutterBinding.ensureInitialized();\n  runtime.registerRuntimeContracts();\n  registerControlledContracts({\n"
    source += ''.join(f"    '{key}': '{value}',\n" for key, value in encoded.items())
    source += '  });\n}\n'
    with output_directory(create=True) as directory:
        temporary = '.controlled-' + secrets.token_hex(16)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory)
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as output:
                os.fchmod(output.fileno(), 0o600)
                output.write(source)
            check_ignored()
            os.replace(temporary, TARGET.name, src_dir_fd=directory, dst_dir_fd=directory)
        finally:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--remove', action='store_true')
    mode.add_argument('--verify-only', action='store_true',
                      help='Print a safe JSON receipt without generating or executing scripts')
    args = parser.parse_args()
    if args.archive is None and not args.remove:
        parser.error('--archive is required')
    if args.remove and args.archive is not None:
        parser.error('--remove does not accept --archive')
    try:
        if args.remove:
            check_ignored()
            with output_directory(create=False) as directory:
                if directory is not None:
                    try:
                        os.unlink(TARGET.name, dir_fd=directory)
                    except FileNotFoundError:
                        pass
            return 0
        report, encoded = verify_archive(args.archive)
        if args.verify_only:
            print(json.dumps(report, indent=2))
            return 0 if report['status'] == 'verified' else 1
        if report['status'] != 'verified':
            raise ArchiveError('Archive verification failed; use --verify-only for safe per-ID statuses')
        check_ignored()
        generate(encoded)
        for row in report['scripts']:
            print(f"{row['id']} SHA256 {row['sha256']}")
        print('Generated complete ignored integration entry; remove after use.')
        return 0
    except ArchiveError as error:
        print(str(error), file=sys.stderr)
    except (OSError, UnicodeError, ValueError):
        print('Archive or output operation failed; no private details emitted', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
