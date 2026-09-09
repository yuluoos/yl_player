"""Compare numeric literals and enum/switch cases against reviewed legacy origins.

An allowlist records each exact token-count delta; edits cannot silently broaden it.
This is a drift alarm, complementary to platform characterization, not a Swift parser.
"""
import collections
import json
from pathlib import Path
import re
import sys


def extract(source):
    # Keep numeric literals out of comments and string messages. Match strings
    # before comments so URL text cannot consume real code after a string.
    source = re.sub(r'"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*', ' ', source, flags=re.S)
    # Range operators delimit literals; their dots are not decimal points.
    numeric_source = re.sub(r'\.\.(?:\.|<)', ' ', source)
    values = collections.Counter('number:' + token for token in re.findall(
        r'(?<![\w.])-?(?:0x[0-9A-Fa-f_]+|\d[\d_]*(?:\.\d[\d_]*)?)(?![\w.])', numeric_source))
    values.update('symbol:' + token for token in re.findall(
        r'\b(?:true|false|kCVPixelFormatType_\w+|kCVPixelBuffer\w+|kAudio\w+)\b|\._(?:Enable\w+|1xRealTimePlayback)', source))
    for case in re.findall(r'\bcase\s+([^\n:;{}]+)', source):
        values['case:' + re.sub(r'\s+', ' ', case).strip()] += 1
    return dict(sorted(values.items()))


def difference(old, new):
    return {key: new.get(key, 0) - old.get(key, 0)
            for key in sorted(old.keys() | new.keys()) if new.get(key, 0) != old.get(key, 0)}


def current_tokens(root, row):
    if ('new_file' in row) == ('new_files' in row):
        raise ValueError('Declare exactly one of new_file or new_files')
    paths = row.get('new_files', [row.get('new_file')])
    if not isinstance(paths, list) or not paths:
        raise ValueError('Current source paths must be a nonempty explicit list')
    seen = set()
    tokens = collections.Counter()
    for name in paths:
        if not isinstance(name, str) or not name or any(c in name for c in '*?[]'):
            raise ValueError('Invalid current source path')
        path = Path(name)
        if path.is_absolute() or path.as_posix() != name or '..' in path.parts:
            raise ValueError('Current source paths must be canonical repository-relative paths')
        resolved = (root / path).resolve()
        if not resolved.is_relative_to(root.resolve()) or not resolved.is_file():
            raise ValueError('Missing or external current source path: ' + name)
        if resolved in seen:
            raise ValueError('Duplicate current source path: ' + name)
        seen.add(resolved)
        tokens.update(extract(resolved.read_text()))
    return dict(sorted(tokens.items()))


def verify(root, manifest):
    failures = []
    for row in manifest:
        old = extract((root / row['old_file']).read_text())
        try:
            new = current_tokens(root, row)
        except ValueError as error:
            failures.append({'reason': str(error), 'old_file': row['old_file']})
            continue
        if old != row['old_tokens']:
            failures.append({'reason': 'Legacy behavioral constants changed', 'old_file': row['old_file']})
        observed = difference(old, new)
        if observed != row['allowed_delta']:
            failures.append({'old_file': row['old_file'], 'new_files': row.get('new_files', [row.get('new_file')]),
                             'expected': row['allowed_delta'], 'observed': observed})
        if observed and not row['reason'].startswith('import/platform abstraction:'):
            failures.append({'reason': 'Missing explicit abstraction reason', 'row': row})
    return failures


def main():
    tool = Path(__file__).resolve().parent
    root = tool.parents[2]
    manifest = json.loads((tool / 'behavioral-constants-allowlist.json').read_text())
    failures = verify(root, manifest)
    if failures:
        print(json.dumps(failures, indent=2))
        return 1
    print(f'Verified {len(manifest)} old/new constant comparisons; only exact allowlisted abstraction deltas remain.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
