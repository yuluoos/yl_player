"""Validate owned media identities without treating runtime smoke as acceptance."""
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / 'packages/yl_player/example/assets/test_media/format_matrix'
CONTAINERS = {'mp4', 'mov', 'matroska', 'webm', 'flv', 'mpegTs', 'mpegPs', 'avi'}
VIDEO = {'h264', 'hevc', 'vp9', 'av1'}
AUDIO = {'aac', 'mp3', 'ac3', 'eac3', 'dts', 'flac', 'opus', 'vorbis'}


def validate_case(row, root):
    name = row['file']
    if not isinstance(name, str) or Path(name).name != name:
        raise ValueError('fixture path must be a basename')
    path = root / name
    if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != row['sha256']:
        raise ValueError('fixture identity mismatch')
    if row['container'] not in CONTAINERS or row['source'] != 'owned-generated':
        raise ValueError('invalid container or provenance')
    if set(row['transports']) != {'file', 'http'}:
        raise ValueError('transport coverage missing')
    if row['integrity'] not in {'valid', 'truncated'} or row['seekability'] not in {'expected_seekable', 'no_cues', 'invalid'}:
        raise ValueError('invalid fixture class')
    duration = row['durationSeconds']
    if isinstance(duration, bool) or not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration <= 0:
        raise ValueError('invalid expected duration')
    if set(row['platforms']) != {'android', 'ios', 'macos'}:
        raise ValueError('platform coverage missing')
    for result in row['platforms'].values():
        if result != {'implementation': 'unverified', 'verification': 'not_run'}:
            raise ValueError('inventory does not establish complete format acceptance')


def validate_coverage(rows):
    if len({r['id'] for r in rows}) != len(rows):
        raise ValueError('duplicate case')
    valid = [r for r in rows if r['integrity'] == 'valid']
    if {r['container'] for r in valid} != CONTAINERS:
        raise ValueError('container coverage missing')
    if not VIDEO <= {r['video']['codec'] for r in valid} or not AUDIO <= {r['audio']['codec'] for r in valid}:
        raise ValueError('codec coverage missing')


def main():
    data = json.loads((Path(__file__).parent / 'cases.json').read_text())
    if data != json.loads((MEDIA / 'cases.json').read_text()):
        raise ValueError('bundled inventory mismatch')
    for row in data['cases']: validate_case(row, MEDIA)
    validate_coverage(data['cases'])
    print(json.dumps({'fixtures': len(data['cases']), 'platform_transport_rows': len(data['cases']) * 6,
                      'full_format_acceptance': 'not_run'}))


if __name__ == '__main__': main()
