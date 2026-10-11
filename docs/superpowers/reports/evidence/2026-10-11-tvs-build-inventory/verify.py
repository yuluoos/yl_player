#!/usr/bin/env python3
"""Recheck this recorded inventory without running Flutter or native tools.

python3 verify.py --player /path/to/yl_player --tvs /path/to/tvs \
    --sdk /path/to/flutter

Requires the captured local/generated inputs, installed Pub packages and Git
baselines. Missing or changed inputs fail; this does not prove a build works.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('player', 'tvs', 'sdk'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    roots = vars(args)
    inventory_path = Path(__file__).with_name('inventory.json')
    inventory = json.loads(inventory_path.read_text())
    tracked = 0
    for entry in inventory['files']:
        data = (roots[entry['repository']] / entry['path']).read_bytes()
        if len(data) != entry['bytes'] or sha256(data) != entry['sha256']:
            raise ValueError('Changed input: ' + entry['path'])
        if entry['tracked']:
            committed = subprocess.check_output([
                'git', '-C', str(roots[entry['repository']]), 'show',
                inventory['baselines'][entry['repository']] + ':' + entry['path'],
            ])
            if data != committed:
                raise ValueError('Baseline mismatch: ' + entry['path'])
            tracked += 1
    metadata = json.loads((args.tvs / '.flutter-plugins-dependencies').read_text())
    plugin_count = 0
    for platform, info in inventory['platforms'].items():
        installed = {p['name']: p for p in metadata['plugins'][platform]}
        if set(installed) != {p['name'] for p in info['plugins']}:
            raise ValueError('Plugin set mismatch: ' + platform)
        for entry in info['plugins']:
            path = Path(installed[entry['name']]['path']) / 'pubspec.yaml'
            if sha256(path.read_bytes()) != entry['installed_pubspec_sha256']:
                raise ValueError('Installed package changed: ' + entry['name'])
            plugin_count += 1
    print(json.dumps({
        'verified_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'inventory_sha256': sha256(inventory_path.read_bytes()),
        'verifier_sha256': sha256(Path(__file__).read_bytes()),
        'input_fingerprints_matched': len(inventory['files']),
        'tracked_inputs_matched_baseline': tracked,
        'installed_plugin_pubspec_fingerprints_matched': plugin_count,
        'result': 'PASS',
        'scope': 'Recheck recorded input bytes only; no builds, dependency resolution, devices, simulators or native execution',
    }, indent=2) + '\n', end='')


if __name__ == '__main__':
    main()
