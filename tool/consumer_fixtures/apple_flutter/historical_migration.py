"""Immutable source proof of accepted Task 1, never a current-semantic gate."""
from contextlib import contextmanager
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile
import tempfile

MANIFEST_SHA256 = 'a0089841742da6ef37e861caca60d355dbfd848b23e25b374b52a3820dc1b5e2'
ORIGIN = '65cdfd5e4a7b22812a66582c16988fb07be59876'
FIXTURE = Path(__file__).with_name('historical_migration')


def _canonical(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or '..' in path.parts or path.as_posix() != name:
        raise ValueError('Noncanonical historical entry')
    return path


@contextmanager
def frozen_tree(fixture=FIXTURE, *, manifest_digest=None, origin=ORIGIN):
    fixture = Path(fixture)
    manifest_bytes = (fixture / 'manifest.json').read_bytes()
    if hashlib.sha256(manifest_bytes).hexdigest() != (manifest_digest or MANIFEST_SHA256):
        raise ValueError('Historical metadata digest changed')
    metadata = json.loads(manifest_bytes)
    if metadata['origin_revision'] != origin:
        raise ValueError('Historical origin changed')
    archive_name = metadata['archive']
    _canonical(archive_name)
    if archive_name != metadata['archive_sha256'] + '.tar.gz':
        raise ValueError('Historical archive is not content addressed')
    archive = (fixture / archive_name).read_bytes()
    if len(archive) != metadata['archive_size'] or hashlib.sha256(archive).hexdigest() != metadata['archive_sha256']:
        raise ValueError('Historical archive digest/size changed')
    expected = {entry['path']: entry for entry in metadata['entries']}
    if len(expected) != len(metadata['entries']):
        raise ValueError('Duplicate historical inventory')
    for name in expected: _canonical(name)
    # Never extract an archive blindly: check every regular file and its exact
    # name, size and bytes before materializing only the expected inventory.
    checked = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        for member in tar:
            _canonical(member.name)
            if not member.isfile() or member.name not in expected or member.name in checked:
                raise ValueError('Unexpected or duplicate historical entry')
            entry = expected[member.name]
            if member.size != entry['size']:
                raise ValueError('Historical entry size changed')
            data = tar.extractfile(member).read(entry['size'] + 1)
            if len(data) != entry['size'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
                raise ValueError('Historical source or metadata entry changed')
            checked[member.name] = data
    if checked.keys() != expected.keys():
        raise ValueError('Missing historical entry')
    with tempfile.TemporaryDirectory(prefix='yl-historical-migration-') as directory:
        root = Path(directory)
        for name, data in checked.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        yield root


def verify_historical(fixture=FIXTURE):
    from behavioral_constants import verify
    with frozen_tree(fixture) as root:
        metadata = json.loads((Path(fixture) / 'manifest.json').read_text())
        rows = json.loads((root / metadata['allowlist']).read_text())
        folds = json.loads((root / metadata['folds']).read_text())
        if len(rows) != 57 or len(folds) != 3:
            raise ValueError('Historical comparison inventory changed')
        return verify(root, rows, folds)
