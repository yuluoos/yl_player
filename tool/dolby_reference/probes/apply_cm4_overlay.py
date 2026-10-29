"""Explicit research overlay; verify all inputs before changing an extracted copy."""
import hashlib
import json
from pathlib import Path


def apply(root, manifest=None):
    root = Path(root).resolve(strict=True)
    if manifest is None:
        manifest = json.loads(Path(__file__).with_name('compressed_cm4_overlay.json').read_text())
    pending = []
    for relative, change in manifest.items():
        relative = Path(relative)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('unsafe overlay path')
        path = (root / relative).resolve(strict=True)
        if not path.is_relative_to(root):
            raise ValueError('overlay escapes extracted source')
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != change['before']:
            raise ValueError('overlay source hash mismatch')
        text = data.decode()
        for old, new in change['edits']:
            if not old or text.count(old) != 1:
                raise ValueError('overlay context mismatch')
            text = text.replace(old, new)
        data = text.encode()
        if hashlib.sha256(data).hexdigest() != change['after']:
            raise ValueError('overlay result hash mismatch')
        pending.append((path, data))
    for path, data in pending:
        path.write_bytes(data)
    return {str(path.relative_to(root)): hashlib.sha256(data).hexdigest() for path, data in pending}
