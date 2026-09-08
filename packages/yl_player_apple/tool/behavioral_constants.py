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


def verify(root, manifest):
    failures = []
    for row in manifest:
        old = extract((root / row['old_file']).read_text())
        new = extract((root / row['new_file']).read_text())
        if old != row['old_tokens']:
            failures.append({'reason': 'Legacy behavioral constants changed', 'old_file': row['old_file']})
        observed = difference(old, new)
        if observed != row['allowed_delta']:
            failures.append({'old_file': row['old_file'], 'new_file': row['new_file'],
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
