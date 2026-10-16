"""Hash built code/resources before launch; compare again after native collection.

Apple framework aliases are omitted: their ordinary target files remain hashed.
Product manifests exclude XCTest bundles, which have a separate test identity.
"""
import base64
import hashlib
import json
from pathlib import Path


def canonical(value):
    """Stable UTF-8 representation shared verbatim with native hash verifiers."""
    return json.dumps(value,sort_keys=True,separators=(',',':')).encode()


def sha_file(path):
    """Stream actual file bytes, never substitute a revision or filename hash."""
    value=hashlib.sha256()
    with open(path,'rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):value.update(chunk)
    return value.hexdigest()


def freeze(root, exclude_tests=False):
    """Create a sorted manifest; caller must persist it before launching tests."""
    root=Path(root); files=[]
    if not root.is_dir():raise ValueError('artifact root missing')
    for path in sorted(root.rglob('*')):
        relative=path.relative_to(root)
        if exclude_tests and any(p.endswith('.xctest') for p in relative.parts):continue
        if path.is_symlink() or not path.is_file():continue
        files.append(dict(path=relative.as_posix(),bytes=path.stat().st_size,sha256=sha_file(path)))
    if not files:raise ValueError('artifact contains no files')
    raw=canonical(files)
    return dict(files=files,excludeTests=exclude_tests,sha256=hashlib.sha256(raw).hexdigest(),manifest=base64.b64encode(raw).decode())


def verify(root, record):
    """Reject additions, removals and byte changes; do not repair the frozen plan."""
    try:return freeze(root,record['excludeTests'])==record
    except (OSError,ValueError,KeyError):return False
