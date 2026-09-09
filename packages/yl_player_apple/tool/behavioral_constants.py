"""Compare numeric literals and enum/switch cases against reviewed legacy origins.

An allowlist records each exact token-count delta; edits cannot silently broaden it.
This is a drift alarm, complementary to platform characterization, not a Swift parser.
"""
import collections
import json
import hashlib
import gzip
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


def swift_code(source):
    # Preserve offsets/newlines so named method scopes remain auditable. This
    # finite fold validator handles the simple reviewed assignment methods only.
    return re.sub(r'"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*',
                  lambda match: re.sub(r'[^\n]', ' ', match.group()), source, flags=re.S)


def brace_body(code, after):
    start = code.find('{', after)
    if start < 0:
        raise ValueError('Structural fold scope has no body')
    depth = 1
    for end in range(start + 1, len(code)):
        depth += (code[end] == '{') - (code[end] == '}')
        if depth == 0:
            return code[start + 1:end]
    raise ValueError('Structural fold scope is unterminated')


def method_body(source, owner, method):
    code = swift_code(source)
    owners = list(re.finditer(r'\bclass\s+' + re.escape(owner) + r'\b', code))
    if len(owners) != 1:
        raise ValueError('Structural fold owner is missing or ambiguous: ' + owner)
    scope = brace_body(code, owners[0].end())
    declarations = list(re.finditer(r'^  (?:private )?func\s+' + re.escape(method) + r'\b', scope, re.M))
    if len(declarations) != 1:
        raise ValueError('Structural fold method is missing or ambiguous: ' + method)
    return brace_body(scope, declarations[0].end())


def read_fold_before(root, fold, cache):
    name = fold['before_snapshot']
    path = Path(name)
    digest = fold['before_sha256']
    if (not re.fullmatch(r'[0-9a-f]{64}', digest) or path.is_absolute()
            or '..' in path.parts or path.as_posix() != name
            or path.name != digest + '.swift.gz'):
        raise ValueError('Invalid content-addressed structural snapshot path')
    resolved = (root / path).resolve()
    if not resolved.is_relative_to(root.resolve()) or not resolved.is_file():
        raise ValueError('Missing or external structural snapshot')
    if resolved in cache:
        saved_digest, saved_size, source = cache[resolved]
        if (saved_digest, saved_size) != (digest, fold['before_size']):
            raise ValueError('Conflicting structural snapshot identity')
        return source
    try:
        raw = gzip.decompress(resolved.read_bytes())
        source = raw.decode('utf-8')
    except (OSError, EOFError, UnicodeError) as error:
        raise ValueError('Corrupt structural snapshot') from error
    if len(raw) != fold['before_size'] or hashlib.sha256(raw).hexdigest() != digest:
        raise ValueError('Structural snapshot source digest/size changed')
    cache[resolved] = (digest, len(raw), source)
    return source


def normalize_structural_folds(root, row, folds, read_before=None, snapshot_cache=None):
    current = collections.Counter(current_tokens(root, row))
    requested = row.get('structural_folds', [])
    if not requested:
        return dict(sorted(current.items()))
    if not isinstance(requested, list) or len(set(requested)) != len(requested):
        raise ValueError('Invalid structural fold selection')
    ids = [fold['id'] for fold in folds]
    if len(set(ids)) != len(ids):
        raise ValueError('Duplicate structural fold record')
    records = dict(zip(ids, folds))
    snapshot_cache = {} if snapshot_cache is None else snapshot_cache
    for identifier in requested:
        if identifier not in records:
            raise ValueError('Unknown structural fold: ' + identifier)
        fold = records[identifier]
        if row.get('new_files') != fold['current_scope'] or row['old_file'] not in fold['legacy_files']:
            raise ValueError('Structural fold applied outside its exact reviewed scope')
        for name in ('after_file', 'caller_file'):
            if fold[name] not in fold['current_scope']:
                raise ValueError('Structural fold path outside current scope')
        # Reuse canonical path/duplicate validation on the complete explicit scope.
        current_tokens(root, {'new_files': fold['current_scope']})
        origin_path = Path(fold['before_file'])
        if origin_path.is_absolute() or '..' in origin_path.parts or origin_path.as_posix() != fold['before_file'] or fold['before_file'] != fold['caller_file']:
            raise ValueError('Invalid structural fold origin path')
        if not re.fullmatch(r'[0-9a-f]{40}', fold['before_revision']):
            raise ValueError('Structural fold origin must retain its full revision')
        before = (read_before(fold['before_revision'], fold['before_file']) if read_before
                  else read_fold_before(root, fold, snapshot_cache))
        if hashlib.sha256(before.encode()).hexdigest() != fold['before_sha256']:
            raise ValueError('Structural fold origin digest changed')
        after = (root / fold['after_file']).read_text()
        caller = (root / fold['caller_file']).read_text()
        token = fold['token']
        if extract(fold['before_statement']) != {token: 1} or extract(fold['after_body']) != {token: 1}:
            raise ValueError('Structural fold literal changed')
        body = method_body(after, fold['after_owner'], fold['after_method'])
        compact = lambda value: re.sub(r'\s+', '', value)
        if compact(body) != compact(fold['after_body']) or extract(body) != {token: fold['after_count']}:
            raise ValueError('Structural fold implementation changed')
        methods = fold['lifecycle_methods']
        if not isinstance(methods, list) or not methods or len(set(methods)) != len(methods):
            raise ValueError('Invalid structural lifecycle mapping')
        if fold['after_count'] != 1 or fold['before_count'] != len(methods):
            raise ValueError('Structural fold occurrence count changed')
        call = fold['call']
        if not re.fullmatch(r'[A-Za-z_]\w*\.' + re.escape(fold['after_method']) + r'\(\)', call):
            raise ValueError('Invalid structural fold call')
        binding = call.split('.')[0]
        if not re.search(r'\blet\s+' + re.escape(binding) + r'\s*:\s*' + re.escape(fold['after_owner']) + r'\b', swift_code(caller)):
            raise ValueError('Structural fold owner binding changed')
        for method in methods:
            old_body = method_body(before, fold['before_owner'], method)
            new_body = method_body(caller, fold['caller_owner'], method)
            if compact(old_body).count(compact(fold['before_statement'])) != 1 or compact(new_body).count(call) != 1:
                raise ValueError('Stale structural lifecycle mapping: ' + method)
        preserved = fold.get('preserved_assignments', [])
        preserved_methods = [entry['before_method'] for entry in preserved]
        if len(set(preserved_methods)) != len(preserved_methods) or set(preserved_methods) & set(methods):
            raise ValueError('Ambiguous preserved structural mapping')
        for entry in preserved:
            old_body = method_body(before, fold['before_owner'], entry['before_method'])
            if entry['after_file'] not in fold['current_scope']:
                raise ValueError('Preserved structural path outside scope')
            kept = method_body((root / entry['after_file']).read_text(), entry['after_owner'], entry['after_method'])
            if compact(old_body).count(compact(fold['before_statement'])) != 1 or compact(kept).count(compact(entry['statement'])) != 1:
                raise ValueError('Preserved structural assignment changed')
            if extract(entry['statement']) != {token: 1}:
                raise ValueError('Preserved structural literal changed')
        if compact(swift_code(before)).count(compact(fold['before_statement'])) != fold['before_count'] + len(preserved):
            raise ValueError('Structural fold old occurrences changed')
        if compact(swift_code(caller)).count(call) != fold['before_count']:
            raise ValueError('Structural fold current call occurrences changed')
        # Reconstitute only the reviewed lexical multiplicity, never a new value.
        current[token] += fold['before_count'] - fold['after_count']
    return dict(sorted(current.items()))


def verify(root, manifest, folds=()):
    failures = []
    snapshot_cache = {}
    for row in manifest:
        old = extract((root / row['old_file']).read_text())
        try:
            new = normalize_structural_folds(root, row, folds, snapshot_cache=snapshot_cache)
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
    fold_path = tool / "behavioral-structural-folds.json"
    folds = json.loads(fold_path.read_text()) if fold_path.is_file() else []
    failures = verify(root, manifest, folds)
    if failures:
        print(json.dumps(failures, indent=2))
        return 1
    print(f'Verified {len(manifest)} old/new constant comparisons; exact abstraction deltas and validated structural folds only.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
