"""Validate the frozen P07 investigation, not a playback certification engine."""
import argparse
import hashlib
import json
from pathlib import Path

PROFILES = ('5', '7-mel', '7-fel', '8.1', '8.2', '8.4')
METADATA = {
    'cm29-base': ('2.9', [1, 5, 6]),
    'cm29-trims': ('2.9', [1, 2, 4, 5, 6]),
    'cm40-base': ('4.0', [1, 5, 6]),
    'cm40-trims': ('4.0', [1, 2, 4, 5, 6, 8]),
}
MISSING = ['original_authorized_input', 'verified_profile_cm_levels',
           'independent_target_reference', 'target_and_frame_alignment',
           'frozen_tolerance', 'physical_output_chain']
STATES = {'arithmetic': 'not_run', 'mapping_quality': 'external_missing',
          'native_dv_signal': 'external_missing'}


class InventoryError(ValueError):
    def __init__(self):
        super().__init__('Dolby investigation inventory is invalid or stale.')


def validate(document):
    """Version 1 deliberately permits no acceptance promotion.

    Obtaining references requires a reviewed schema/evidence change, not flipping
    a status in this source-inspection matrix. CM/profile combinations are inquiry
    targets; their presence does not assert that such a conforming stream exists.
    """
    try:
        if (set(document) != {'schema_version', 'phase', 'baseline_commit', 'cases'}
                or document['schema_version'] != 1
                or document['phase'] != 'reference_investigation'
                or not _hex(document['baseline_commit'], 40)):
            raise InventoryError()
        expected = {(p, m) for p in PROFILES for m in METADATA}
        seen = set()
        for row in document['cases']:
            if set(row) != {'id', 'profile', 'metadata_set', 'cm', 'levels',
                            'input_sha256', 'reference_sha256', 'tolerance',
                            'platforms', 'missing', 'applicability'}:
                raise InventoryError()
            key = row['profile'], row['metadata_set']
            if key not in expected or key in seen:
                raise InventoryError()
            seen.add(key)
            cm, levels = METADATA[row['metadata_set']]
            if (row['id'] != 'p' + key[0] + '-' + key[1]
                    or row['cm'] != cm or row['levels'] != levels
                    or row['applicability'] != 'to_verify'
                    or any(row[k] is not None for k in ['input_sha256', 'reference_sha256', 'tolerance'])
                    or row['missing'] != MISSING
                    or row['platforms'] != {p: STATES for p in ['android', 'ios', 'macos']}):
                raise InventoryError()
        if seen != expected:
            raise InventoryError()
    except (KeyError, TypeError, ValueError):
        raise InventoryError() from None
    return {'investigation_rows': len(seen), 'platform_rows': len(seen) * 3,
            'mapping_quality_passes': 0, 'native_dv_signal_passes': 0,
            'task1': 'incomplete'}


def _hex(value, length):
    return (isinstance(value, str) and len(value) == length
            and all(c in '0123456789abcdef' for c in value))


def verify_snapshot(root, rows):
    """Explicit baseline check; later intentional source changes need rebaselining."""
    try:
        if not rows:
            raise InventoryError()
        root = root.resolve()
        seen = set()
        for row in rows:
            if set(row) != {'path', 'sha256'} or not _hex(row['sha256'], 64):
                raise InventoryError()
            relative = Path(row['path'])
            if relative.is_absolute() or '..' in relative.parts or row['path'] in seen:
                raise InventoryError()
            seen.add(row['path'])
            target = (root / relative).resolve()
            if not target.is_relative_to(root) or not target.is_file():
                raise InventoryError()
            if hashlib.sha256(target.read_bytes()).hexdigest() != row['sha256']:
                raise InventoryError()
    except (KeyError, TypeError, ValueError, OSError):
        raise InventoryError() from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-snapshot', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    try:
        report = validate(json.loads((root / 'tool/dolby_reference/cases.json').read_text()))
        if args.check_snapshot:
            snapshot = json.loads((root / 'tool/dolby_reference/baseline.json').read_text())
            verify_snapshot(root, snapshot['sources'])
            report['source_snapshot'] = 'matched'
        print(json.dumps(report, sort_keys=True))
        return 0  # inventory validity only, never playback acceptance
    except (InventoryError, OSError, ValueError):
        print('{"code":"dolby.inventory_invalid"}')
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
